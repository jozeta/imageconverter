import CoreGraphics
import Foundation
import ImageconverterCore

/// What the difference image depends on: the selected item, the full-size images of its estimate and the region
/// on screen (the whole image at fit).
struct DifferenceKey: Equatable {
    let item: URL
    let original: ObjectIdentifier?
    let encoded: ObjectIdentifier?
    let region: CGRect
}

/// What the quality ladder's encodes depend on. Quality and compression mode are left out (the ladder sets its
/// own), so picking a tile doesn't encode again; the region only changes the crops (`LadderCropKey`).
struct LadderKey: Equatable {
    let item: InputItem
    let pipeline: Pipeline
}

/// A new region for the ladder's existing encodes.
struct LadderCropKey: Equatable {
    let item: URL
    let region: CGRect
}

/// Images handed to and from the detached renders (CGImage is immutable).
private struct ImagePair: @unchecked Sendable {
    let first: CGImage
    let second: CGImage
}

private struct LadderRender: Sendable {
    let rungs: [QualityLadder.Rung]
    let originalBytes: Int?
    let failure: String?
}

extension AppModel {
    nonisolated static let ladderQualities: [Double] = [0.4, 0.6, 0.8, 0.95]
    static let ladderDebounce = Duration.milliseconds(400)
    /// Pan and zoom settle this long before a region is cropped again.
    static let regionDebounce = Duration.milliseconds(150)
    /// About twice a tile's pixel size: the tiles stay sharp, four rungs stay small.
    nonisolated static let ladderMaxSide = 800
    /// A difference image is never larger than this on its longer side (at fit it is scaled down to it).
    nonisolated static let differenceMaxSide = 2048

    private var selectedSource: URL? { selectedItemIndex.map { items[$0].source } }

    /// The current estimate when it belongs to the selected item.
    private var selectedEstimate: SizeEstimate? {
        sizeEstimate.flatMap { $0.item == selectedSource ? $0 : nil }
    }

    /// The part of the reference image on screen, in unit coordinates, rounded so tiny pans don't render again.
    var compareRegion: CGRect {
        guard let reference = zoom.reference, zoom.state.isZoomed else { return QualityLadder.unitRegion }
        let region = ZoomMath.visibleRegion(zoom.state, imagePixels: reference.imagePixels, view: reference.view)
        func round(_ value: CGFloat) -> CGFloat { (value * 500).rounded() / 500 }
        return CGRect(x: round(region.minX), y: round(region.minY), width: round(region.width), height: round(region.height))
    }

    /// Nil unless the Difference mode is shown for a selected item.
    var differenceKey: DifferenceKey? {
        guard compare.mode == .difference, !previewCollapsed, let source = selectedSource else { return nil }
        let full = selectedEstimate?.full
        return DifferenceKey(item: source, original: full?.original.map(ObjectIdentifier.init),
                             encoded: full?.encoded.map(ObjectIdentifier.init), region: compareRegion)
    }

    /// The difference of the region on screen (a crop when zoomed, the whole image scaled down at fit) between the
    /// estimate's full-size original and encoded result, off the main actor. Runs from the view's
    /// `task(id: differenceKey)`, so a new key cancels it (the Core loop stops between strips).
    func renderDifference(for key: DifferenceKey?) async {
        guard let key else {
            compare.difference = nil
            return
        }
        // The previous image stays while the same item's region is re-rendered, so panning doesn't flash.
        if compare.difference?.item != key.item { compare.difference = nil }
        let pair: ImagePair
        switch differenceInputs() {
        case .pending: return
        case .unavailable(let reason):
            compare.difference = .unavailable(key.item, reason)
            return
        case .ready(let ready): pair = ready
        }
        if compare.difference?.image != nil {
            do { try await Task.sleep(for: Self.regionDebounce) } catch { return }
        }
        let region = key.region
        let original = pair.first
        let worker = Task.detached(priority: .userInitiated) { () -> Result<ImageDifference.Comparison, Error> in
            Result { try ImageDifference.compare(before: pair.first, after: pair.second, region: region,
                                                 maxSide: Self.differenceMaxSide) }
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, differenceKey == key else { return }
        apply(result, for: key, fullSize: CGSize(width: original.width, height: original.height))
    }

    private func apply(_ result: Result<ImageDifference.Comparison, Error>, for key: DifferenceKey, fullSize: CGSize) {
        let region = key.region
        switch result {
        case .success(let comparison):
            let regionPixels = RegionCrop.pixelRect(region, width: Int(fullSize.width), height: Int(fullSize.height))
            compare.difference = DifferenceOutcome(
                item: key.item, image: comparison.image, stats: comparison.stats, fullSize: fullSize, region: region,
                scaled: CGFloat(comparison.image.width) < regionPixels.width, unavailable: nil)
        case .failure(let error as ImageDifference.CompareError) where error == .sizeMismatch:
            compare.difference = .unavailable(key.item, "Not available: the size changes")
        case .failure(is CancellationError):
            return
        case .failure:
            compare.difference = .unavailable(key.item, "The difference couldn't be computed")
        }
    }

    private enum DifferenceInputs {
        /// Still estimating.
        case pending
        case unavailable(String)
        case ready(ImagePair)
    }

    /// The estimate's full-size original and encoded result, or why there is no difference to show.
    private func differenceInputs() -> DifferenceInputs {
        guard let estimate = selectedEstimate else {
            return estimateFailed ? .unavailable(estimateFailure ?? "Not available: the result couldn't be encoded") : .pending
        }
        guard let original = estimate.full?.original, let encoded = estimate.full?.encoded else {
            return .unavailable(estimate.full == nil ? "Not available: the result couldn't be encoded"
                                                     : "Not available: the file is copied unchanged")
        }
        guard original.width == encoded.width, original.height == encoded.height else {
            return .unavailable("Not available: the size changes")
        }
        return .ready(ImagePair(first: original, second: encoded))
    }

    /// Nil unless the quality panel is open for a selected item in a format with a quality setting.
    var ladderKey: LadderKey? {
        guard compare.showsQuality, !previewCollapsed, !isRunning, pipeline.output.format.supportsQuality,
              let index = selectedItemIndex else { return nil }
        var normalized = pipeline
        normalized.output.quality = OutputSettings.defaultQuality
        normalized.output.compression = .quality
        return LadderKey(item: items[index], pipeline: normalized)
    }

    /// Encodes the selected item at 40/60/80/95 % off the main actor, 400 ms after the last change, keeping each
    /// encode's bytes and a crop of the region on screen. Runs from the view's `task(id: ladderKey)`.
    func renderLadder(for key: LadderKey?) async {
        compare.ladder = nil
        guard let key else { return }
        do { try await Task.sleep(for: Self.ladderDebounce) } catch { return }
        let region = compareRegion
        let presets = presetLibrary
        let caches = previewRenderer.caches
        let worker = Task.detached(priority: .userInitiated) { () -> LadderRender in
            let original = (try? key.item.source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            do {
                let rungs = try QualityLadder.render(item: key.item, pipeline: key.pipeline, qualities: Self.ladderQualities,
                                                     region: region, maxSide: Self.ladderMaxSide, presets: presets,
                                                     enlarger: SystemSuperResolution.inApp, caches: caches)
                return LadderRender(rungs: rungs, originalBytes: original, failure: nil)
            } catch is CancellationError {
                return LadderRender(rungs: [], originalBytes: original, failure: nil)
            } catch QualityLadder.LadderError.tooLarge {
                return LadderRender(rungs: [], originalBytes: original, failure: "Too large to compare here")
            } catch let error as ConversionError {
                return LadderRender(rungs: [], originalBytes: original, failure: error.reason)
            } catch {
                return LadderRender(rungs: [], originalBytes: original, failure: "The image couldn't be encoded")
            }
        }
        let render = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, ladderKey == key else { return }
        compare.ladder = LadderOutcome(
            item: key.item.source, rungs: render.rungs, region: region, originalBytes: render.originalBytes,
            failure: render.failure ?? (render.rungs.isEmpty ? "This image has no quality to compare" : nil))
    }

    /// Nil unless there are rungs whose crops show another region than the one on screen.
    var ladderCropKey: LadderCropKey? {
        guard let ladder = compare.ladder, !ladder.rungs.isEmpty else { return nil }
        let region = compareRegion
        return region == ladder.region ? nil : LadderCropKey(item: ladder.item, region: region)
    }

    /// Crops the kept encodes again for the region on screen (no new encode).
    func recropLadder(for key: LadderCropKey?) async {
        guard let key, let rungs = compare.ladder?.rungs else { return }
        do { try await Task.sleep(for: Self.regionDebounce) } catch { return }
        let worker = Task.detached(priority: .userInitiated) { () -> [QualityLadder.Rung]? in
            var cropped: [QualityLadder.Rung] = []
            for rung in rungs {
                guard !Task.isCancelled,
                      let image = QualityLadder.crop(rung.data, region: key.region, maxSide: Self.ladderMaxSide) else { return nil }
                cropped.append(QualityLadder.Rung(quality: rung.quality, bytes: rung.bytes, data: rung.data, image: image))
            }
            return cropped
        }
        let cropped = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, let cropped, var ladder = compare.ladder, ladder.item == key.item else { return }
        ladder.rungs = cropped
        ladder.region = key.region
        compare.ladder = ladder
    }

    /// A quality tile was picked: use it as the output quality. Target size and Smart ignore the quality, so
    /// they switch to plain Quality; Maximum size keeps its limit and starts from the picked quality.
    func chooseQuality(_ quality: Double) {
        pipeline.output.quality = quality
        switch pipeline.output.compression {
        case .targetSize, .smart: pipeline.output.compression = .quality
        case .quality, .maxSize: break
        }
    }

    /// Reads one list row's dimensions and file size off the main actor, once per file.
    func loadSummary(for url: URL) async {
        guard compare.summaries[url] == nil else { return }
        let summary = await Task.detached(priority: .utility) { () -> ItemSummary in
            let size = ImageLoader.header(of: url)?.uprightSize
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return ItemSummary(width: size?.width, height: size?.height, bytes: bytes)
        }.value
        guard !Task.isCancelled, compare.activeSources.contains(url) else { return }
        compare.summaries[url] = summary
    }
}
