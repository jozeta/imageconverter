import CoreGraphics
import Foundation

/// A rendered before/after pair for the preview pane. Both images fit within the renderer's
/// `displayMax` on the long side; the sizes are the true (full-resolution) ones.
public struct PreviewResult: @unchecked Sendable {
    public let before: CGImage
    public let after: CGImage
    public let sourceName: String
    public let outputName: String
    public let sourceSize: (Int, Int)
    public let outputSize: (Int, Int)
}

public enum PreviewOutcome: Sendable {
    case ready(PreviewResult)
    case failed(reason: String)
}

/// Renders the preview of one item through the same load and apply path as the batch (no encode).
/// It keeps the decoded source of the last item and the watermark images of the last pipeline.
public actor PreviewRenderer {
    private let maxPixels: Int
    private let displayMax: Int
    private var cachedURL: URL?
    private var cachedSource: CGImage?
    private var cachedAssets: WatermarkAssets?
    private var cachedAssetPaths: [String]?
    /// How many times a source was decoded (for tests).
    private(set) var decodeCount = 0

    public init(maxPixels: Int = ImageLoader.defaultMaxPixels, displayMax: Int = 1600) {
        self.maxPixels = maxPixels
        self.displayMax = max(1, displayMax)
    }

    public func render(item: InputItem, index: Int, pipeline: Pipeline) async -> PreviewOutcome {
        let cancelled = PreviewOutcome.failed(reason: "Cancelled")
        if Task.isCancelled { return cancelled }
        let assets = watermarkAssets(for: pipeline)
        if assets.hasMissing(for: pipeline) { return .failed(reason: ConversionError.watermarkImageUnreadable.reason) }
        let source: CGImage
        do {
            source = try sourceImage(for: item.source)
        } catch let error as ConversionError {
            return .failed(reason: error.reason)
        } catch {
            return .failed(reason: ConversionError.unreadable.reason)
        }
        if Task.isCancelled { return cancelled }
        let result: CGImage
        do {
            result = try pipeline.apply(to: source, assets: assets)
        } catch let error as ConversionError {
            return .failed(reason: error.reason)
        } catch {
            return .failed(reason: ConversionError.processingFailed("preview").reason)
        }
        if Task.isCancelled { return cancelled }
        guard let before = fit(source), let after = fit(result) else {
            return .failed(reason: ConversionError.processingFailed("preview").reason)
        }
        return .ready(PreviewResult(
            before: before, after: after, sourceName: item.source.lastPathComponent,
            outputName: outputName(for: item, index: index, pipeline: pipeline),
            sourceSize: (source.width, source.height), outputSize: (result.width, result.height)))
    }

    private func outputName(for item: InputItem, index: Int, pipeline: Pipeline) -> String {
        let base = RenameRendering.baseName(for: item, index: index, pipeline: pipeline)
            ?? item.source.deletingPathExtension().lastPathComponent
        let ext = pipeline.output.format.fileExtensions.first ?? ""
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private func sourceImage(for url: URL) throws -> CGImage {
        if cachedURL == url, let cachedSource { return cachedSource }
        decodeCount += 1
        let loaded = try ImageLoader.load(url, maxPixels: maxPixels)
        cachedURL = url
        cachedSource = loaded.image
        return loaded.image
    }

    private func watermarkAssets(for pipeline: Pipeline) -> WatermarkAssets {
        let paths = pipeline.steps.compactMap { step -> String? in
            guard step.isEnabled, case .watermark(let options) = step.operation,
                  case .image(let watermark) = options.content else { return nil }
            return watermark.path
        }
        if let cachedAssets, cachedAssetPaths == paths, !cachedAssets.hasMissing(for: pipeline) { return cachedAssets }
        let assets = WatermarkAssets.load(for: pipeline, maxPixels: maxPixels)
        cachedAssets = assets
        cachedAssetPaths = paths
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
