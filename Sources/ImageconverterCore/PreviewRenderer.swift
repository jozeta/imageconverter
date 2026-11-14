import CoreGraphics
import Foundation

/// A rendered before/after pair for the preview pane. Both images fit within the renderer's
/// `displayMax` on the long side; the sizes are the true (full-resolution) ones.
public struct PreviewResult: @unchecked Sendable {
    public let before: CGImage
    public let after: CGImage
    /// The rendered item's file, so a caller can tell which item this result belongs to.
    public let source: URL
    public let sourceName: String
    public let outputName: String
    public let sourceSize: (Int, Int)
    public let outputSize: (Int, Int)
    /// Where this item would be written (planned alone, so no collision numbers).
    public let outputURL: URL
    /// The source file's size on disk.
    public let sourceFileSize: Int?
    /// What the batch would do with this item once its conditions are resolved; for a copy or a skip the
    /// after image is the before image.
    public let disposition: Disposition
    /// "Skipped by a condition" / "Copied unchanged"; nil when the item is processed.
    public let statusNote: String?
}

public enum PreviewOutcome: Sendable {
    case ready(PreviewResult)
    case failed(reason: String)
}

/// Renders the preview of one item through the same load and apply path as the batch (no encode).
/// It keeps the decoded source of the last item and the watermark images of the last pipeline.
public actor PreviewRenderer {
    /// Sources above this many pixels are rendered without being cached.
    static let maxCachedPixels = 50_000_000

    /// Identifies a file's content cheaply: a rewritten file changes its date or size.
    private struct FileKey: Equatable {
        let url: URL
        let modified: Date?
        let size: Int?

        init(_ url: URL) {
            let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            self.url = url
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    private struct CachedSource {
        let key: FileKey
        let image: CGImage
        let display: CGImage
        /// The header properties, for the watermark's tokens.
        let properties: [String: Any]
    }

    private let maxPixels: Int
    private let displayMax: Int
    private var cachedSource: CachedSource?
    private var cachedAssets: WatermarkAssets?
    private var cachedAssetKeys: [FileKey]?
    /// How many times a source was decoded (for tests).
    private(set) var decodeCount = 0
    /// How many times the watermark images were loaded (for tests).
    private(set) var assetLoadCount = 0

    public init(maxPixels: Int = ImageLoader.defaultMaxPixels, displayMax: Int = 1600) {
        self.maxPixels = maxPixels
        self.displayMax = max(1, displayMax)
    }

    /// Releases the cached source and watermark images (call when a batch starts or finishes).
    public func purge() {
        cachedSource = nil
        cachedAssets = nil
        cachedAssetKeys = nil
    }

    /// Renders the before and after of `item`. `outputName` is what `OutputPlanner` would name this
    /// file for `mode` (nil: new-folder mode with no folder yet, named as if a folder existed). It
    /// plans the one item alone, so the batch's collision numbers (`_2`) are not shown.
    /// Conditions are resolved for this item first (from its header), so the preview shows its own branch.
    public func render(item: InputItem, index: Int, pipeline unresolved: Pipeline, mode: OutputMode? = nil) async
        -> PreviewOutcome {
        let cancelled = PreviewOutcome.failed(reason: "Cancelled")
        if Task.isCancelled { return cancelled }
        let resolved = unresolved.resolved(forSource: item.source, maxPixels: maxPixels)
        let pipeline = resolved.pipeline
        if resolved.disposition != .process { return unchanged(item: item, index: index, resolved: resolved, mode: mode) }
        let assets = watermarkAssets(for: pipeline)
        if let missing = assets.missingError(for: pipeline) { return .failed(reason: missing.reason) }
        let source: CGImage
        let before: CGImage
        let properties: [String: Any]
        do {
            let loaded = try sourceImages(for: item.source)
            (source, before, properties) = (loaded.image, loaded.display, loaded.properties)
        } catch let error as ConversionError {
            return .failed(reason: error.reason)
        } catch {
            return .failed(reason: ConversionError.unreadable.reason)
        }
        if Task.isCancelled { return cancelled }
        let result: CGImage
        do {
            // Synchronous and not interruptible; cancellation is only seen before and after it.
            let context = pipeline.watermarkTextContext(source: item.source, properties: properties)
            result = try pipeline.apply(to: source, assets: assets, textContext: context)
        } catch let error as ConversionError {
            return .failed(reason: error.reason)
        } catch {
            return .failed(reason: ConversionError.processingFailed("preview").reason)
        }
        if Task.isCancelled { return cancelled }
        guard let after = fit(result) else {
            return .failed(reason: ConversionError.processingFailed("preview").reason)
        }
        let destination = outputDestination(for: item, index: index, pipeline: pipeline, mode: mode)
        let fileSize = (try? item.source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return .ready(PreviewResult(
            before: before, after: after, source: item.source, sourceName: item.source.lastPathComponent,
            outputName: destination.lastPathComponent,
            sourceSize: (source.width, source.height), outputSize: (result.width, result.height),
            outputURL: destination, sourceFileSize: fileSize, disposition: .process, statusNote: nil))
    }

    /// A copied or skipped item: the source on both sides, nothing applied.
    private func unchanged(item: InputItem, index: Int, resolved: ResolvedPipeline, mode: OutputMode?) -> PreviewOutcome {
        let loaded: CachedSource
        do { loaded = try sourceImages(for: item.source) } catch let error as ConversionError {
            return .failed(reason: error.reason)
        } catch {
            return .failed(reason: ConversionError.unreadable.reason)
        }
        let destination = resolved.disposition == .copyOriginal
            ? outputDestination(for: item, index: index, pipeline: resolved.pipeline, mode: mode, copy: true)
            : item.source
        let size = (loaded.image.width, loaded.image.height)
        let fileSize = (try? item.source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return .ready(PreviewResult(
            before: loaded.display, after: loaded.display, source: item.source, sourceName: item.source.lastPathComponent,
            outputName: resolved.disposition == .skip ? ConditionalStep.skippedReason : destination.lastPathComponent, sourceSize: size,
            outputSize: size, outputURL: destination, sourceFileSize: fileSize, disposition: resolved.disposition,
            statusNote: resolved.statusNote))
    }

    private func outputDestination(for item: InputItem, index: Int, pipeline: Pipeline, mode: OutputMode?,
                                   copy: Bool = false) -> URL {
        let base = RenameRendering.baseName(for: item, index: index, pipeline: pipeline, isCopy: copy)
        let target = copy ? OutputTarget.copyOfOriginal(item, baseName: base)
            : OutputTarget(item: item, format: pipeline.output.format, baseName: base)
        let plan = OutputPlanner.plan(
            [target], mode: mode ?? .newFolder(FileManager.default.temporaryDirectory), fileExists: { _ in false })
        guard let destination = plan.first?.destination else { return item.source }
        // No mode yet: show the name in the source's own folder (planning there would call it `a_2`).
        if mode == nil { return item.source.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent) }
        return destination
    }

    private func sourceImages(for url: URL) throws -> CachedSource {
        let key = FileKey(url)
        if let cachedSource, cachedSource.key == key { return cachedSource }
        cachedSource = nil
        decodeCount += 1
        let loaded = try ImageLoader.load(url, maxPixels: maxPixels)
        let image = loaded.image
        guard let display = fit(image) else { throw ConversionError.processingFailed("preview") }
        let decoded = CachedSource(key: key, image: image, display: display, properties: loaded.properties)
        if image.width <= Self.maxCachedPixels / max(1, image.height) { cachedSource = decoded }
        return decoded
    }

    private func watermarkAssets(for pipeline: Pipeline) -> WatermarkAssets {
        let keys = pipeline.steps.compactMap { step -> FileKey? in
            guard step.isEnabled, case .watermark(let options) = step.operation,
                  case .image(let watermark) = options.content else { return nil }
            return FileKey(URL(fileURLWithPath: watermark.path))
        }
        if let cachedAssets, cachedAssetKeys == keys, !cachedAssets.hasMissing(for: pipeline) { return cachedAssets }
        assetLoadCount += 1
        let assets = WatermarkAssets.load(for: pipeline, maxPixels: maxPixels)
        cachedAssets = assets
        cachedAssetKeys = keys
        return assets
    }

    /// `image` scaled down to fit `displayMax` on the long side (unchanged when it already fits).
    private func fit(_ image: CGImage) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > displayMax else { return image }
        let scale = Double(displayMax) / Double(longSide)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = ImageOps.makeContext(width: width, height: height, like: image) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
