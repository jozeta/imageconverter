import CoreGraphics
import Foundation
import ImageconverterCore

/// What the difference image depends on: the selected item and the full-size images of its estimate.
struct DifferenceKey: Equatable {
    let item: URL
    let original: ObjectIdentifier?
    let encoded: ObjectIdentifier?
}

/// What the quality ladder depends on. Quality and compression mode are left out (the ladder sets its own),
/// so picking a tile doesn't render the ladder again.
struct LadderKey: Equatable {
    let item: InputItem
    let pipeline: Pipeline
}

/// Images handed to and from the detached renders (CGImage is immutable).
private struct ImagePair: @unchecked Sendable {
    let first: CGImage?
    let second: CGImage?
}

private struct DifferenceRender: @unchecked Sendable {
    let image: CGImage?
    let stats: ImageDifference.Stats?
}

private struct LadderRender: Sendable {
    let rungs: [QualityLadder.Rung]
    let originalBytes: Int?
    let failure: String?
}

extension AppModel {
    nonisolated static let ladderQualities: [Double] = [0.4, 0.6, 0.8, 0.95]
    static let ladderDebounce = Duration.milliseconds(400)

    private var selectedSource: URL? { selectedItemIndex.map { items[$0].source } }

    /// The current estimate when it belongs to the selected item.
    private var selectedEstimate: SizeEstimate? {
        sizeEstimate.flatMap { $0.item == selectedSource ? $0 : nil }
    }

    /// Nil unless the Difference mode is shown for a selected item.
    var differenceKey: DifferenceKey? {
        guard compare.mode == .difference, !previewCollapsed, let source = selectedSource else { return nil }
        let full = selectedEstimate?.full
        return DifferenceKey(item: source, original: full?.original.map(ObjectIdentifier.init),
                             encoded: full?.encoded.map(ObjectIdentifier.init))
    }

    /// Computes the amplified difference of the estimate's full-size original and encoded result off the main
    /// actor. Runs from the view's `task(id: differenceKey)`, so a new key cancels it.
    func renderDifference(for key: DifferenceKey?) async {
        compare.difference = nil
        guard let key else { return }
        guard let estimate = selectedEstimate else {
            // Still estimating; the key changes again when the estimate lands.
            if estimateFailed {
                compare.difference = DifferenceOutcome(item: key.item, image: nil, stats: nil,
                                                       unavailable: estimateFailure ?? "Not available: the result couldn't be encoded")
            }
            return
        }
        guard let original = estimate.full?.original, let encoded = estimate.full?.encoded else {
            let reason = estimate.full == nil ? "Not available: the result couldn't be encoded"
                                              : "Not available: the file is copied unchanged"
            compare.difference = DifferenceOutcome(item: key.item, image: nil, stats: nil, unavailable: reason)
            return
        }
        guard original.width == encoded.width, original.height == encoded.height else {
            compare.difference = DifferenceOutcome(item: key.item, image: nil, stats: nil,
                                                   unavailable: "Not available: the size changes")
            return
        }
        let pair = ImagePair(first: original, second: encoded)
        let worker = Task.detached(priority: .userInitiated) { () -> DifferenceRender? in
            guard let before = pair.first, let after = pair.second, !Task.isCancelled else { return nil }
            let image = ImageDifference.render(before: before, after: after)
            guard !Task.isCancelled else { return nil }
            return DifferenceRender(image: image, stats: ImageDifference.stats(before: before, after: after))
        }
        let render = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, differenceKey == key, let render else { return }
        compare.difference = DifferenceOutcome(
            item: key.item, image: render.image, stats: render.stats,
            unavailable: render.image == nil ? "Not available: the size changes" : nil)
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

    /// Encodes the selected item at 40/60/80/95 % off the main actor, 400 ms after the last change.
    /// Runs from the view's `task(id: ladderKey)`: a new selection or pipeline cancels it.
    func renderLadder(for key: LadderKey?) async {
        compare.ladder = nil
        guard let key else { return }
        do { try await Task.sleep(for: Self.ladderDebounce) } catch { return }
        let worker = Task.detached(priority: .userInitiated) { () -> LadderRender in
            let original = (try? key.item.source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            do {
                let rungs = try QualityLadder.render(item: key.item, pipeline: key.pipeline, qualities: Self.ladderQualities)
                return LadderRender(rungs: rungs, originalBytes: original, failure: nil)
            } catch is CancellationError {
                return LadderRender(rungs: [], originalBytes: original, failure: nil)
            } catch let error as ConversionError {
                return LadderRender(rungs: [], originalBytes: original, failure: error.reason)
            } catch {
                return LadderRender(rungs: [], originalBytes: original, failure: "The image couldn't be encoded")
            }
        }
        let render = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, ladderKey == key else { return }
        compare.ladder = LadderOutcome(item: key.item.source, rungs: render.rungs, originalBytes: render.originalBytes,
                                       failure: render.failure ?? (render.rungs.isEmpty ? "This image has no quality to compare" : nil))
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
        guard !Task.isCancelled, items.contains(where: { $0.source == url }) else { return }
        compare.summaries[url] = summary
    }
}
