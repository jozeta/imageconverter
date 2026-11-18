import CoreGraphics
import Foundation
import ImageIO

/// When the preview and the size estimate start: at once for a newly selected image, after the last edit otherwise
/// (a slider sends many), and how a quick proxy is followed by the exact render.
public enum PreviewTiming {
    /// The wait after the last pipeline edit before the exact preview render.
    public static let editDelay = Duration.milliseconds(300)
    /// The wait after the last pipeline edit before the size estimate (a full encode).
    public static let estimateEditDelay = Duration.milliseconds(400)

    /// Whether the result on screen (from `shown`) may stay up once the render for `selected` starts a Redact
    /// detection: only when it is the same image. Detection takes seconds, and another image's result would stand in
    /// for this one meanwhile (with this image's name above it); the stage shows the detection status instead.
    public static func keepsShown(_ shown: URL?, whileDetectingFor selected: URL) -> Bool {
        shown == nil || shown == selected
    }

    /// No delay when the selected image changed (a click is one event); `editDelay` for edits.
    public static func previewDelay(selectionChanged: Bool) -> Duration {
        selectionChanged ? .zero : editDelay
    }

    /// No delay when the selected image changed; `estimateEditDelay` for edits.
    public static func estimateDelay(selectionChanged: Bool) -> Duration {
        selectionChanged ? .zero : estimateEditDelay
    }

    /// Delivers `proxy`'s result at once (when there is one), then `exact`'s once `exactDelay` has passed since the
    /// call. The timer runs while the proxy renders. A cancelled wait (a newer edit) skips the exact render, so while
    /// a slider moves only proxies are shown. `deliver`'s flag is true for the exact (final) result.
    public static func run<Value: Sendable>(
        exactDelay: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        proxy: (() async -> Value?)?,
        exact: () async -> Value?,
        deliver: (Value, _ final: Bool) async -> Void
    ) async {
        let timer: Task<Bool, Never>? = exactDelay > .zero ? Task {
            do { try await sleep(exactDelay) } catch { return false }
            return !Task.isCancelled
        } : nil
        let waited = await withTaskCancellationHandler {
            if let proxy, let early = await proxy(), !Task.isCancelled { await deliver(early, false) }
            return await timer?.value ?? true
        } onCancel: { timer?.cancel() }
        guard waited, !Task.isCancelled, let result = await exact(), !Task.isCancelled else { return }
        await deliver(result, true)
    }
}

/// The preview's quick stand-in: the source decoded near display size and run through a pipeline whose look doesn't
/// depend on the pixel count (`Pipeline.isScaleInvariant`). It is shown only until the exact render replaces it.
public enum PreviewProxy {
    /// The decode size for a proxy of a source whose long side is `sourceLongSide`: at least `target`; a JPEG decodes
    /// cheaply only at source / 2^k (DCT scaling), so it is rounded up to the smallest such size. Nil when that isn't
    /// at most half the source (rounded up) (the exact render is then about as quick).
    public static func decodeLongSide(sourceLongSide: Int, target: Int, jpeg: Bool) -> Int? {
        guard sourceLongSide > 0, target > 0 else { return nil }
        var size = target
        if jpeg {
            var scale = 1
            while (sourceLongSide + 2 * scale - 1) / (2 * scale) >= target { scale *= 2 }
            size = (sourceLongSide + scale - 1) / scale
        }
        return size <= (sourceLongSide + 1) / 2 ? size : nil
    }

    /// True when the file's content is JPEG (whatever its extension).
    static func isJPEG(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return false }
        return CGImageSourceGetType(source) as String? == "public.jpeg"
    }

    /// The pipeline to run on a proxy decoded at `decodedLongSide` for a `sourceWidth` x `sourceHeight` source, shown
    /// fitted to `displayMax`: every resize becomes an exact scale to the size it makes at full size, times the
    /// display's scale of the full output, so the proxy's result is the exact result's display size.
    static func pipeline(for pipeline: Pipeline, sourceWidth: Int, sourceHeight: Int, displayMax: Int) -> Pipeline {
        let output = pipeline.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let scale = min(1, Double(displayMax) / Double(max(1, output.width, output.height)))
        var proxy = pipeline
        var size = CGSize(width: max(1, sourceWidth), height: max(1, sourceHeight))
        for (index, step) in pipeline.steps.enumerated() where step.isEnabled {
            let next = Pipeline.size(after: step.operation, from: size)
            if case .resize(var options) = step.operation {
                options.mode = .exactSize(width: max(1, Int((next.width * scale).rounded())),
                                          height: max(1, Int((next.height * scale).rounded())), fill: .stretch)
                options.allowEnlarge = true
                proxy.steps[index].operation = .resize(options)
            }
            size = next
        }
        return proxy
    }
}

extension Pipeline {
    /// True when every enabled image step looks the same on a smaller copy of the image, so a preview proxy is a fair
    /// stand-in: Adjust without sharpening, noise reduction, negative Highlights or Shadows (soften and definition
    /// scale with the image), Color
    /// without colour reduction, 90° turns and flips without an angle, and resizes by percentage, fit or edge (not to an
    /// exact size, not nearest neighbour, not ML enlarge). Crop, Canvas, Perspective, Trim, Watermark, Redact and
    /// conditions work in pixels or on content, so they never get a proxy. Metadata and Rename don't touch pixels.
    public var isScaleInvariant: Bool {
        steps.allSatisfy { step in
            guard step.isEnabled else { return true }
            switch step.operation {
            case .adjust(let options):
                // Highlights below 0 and Shadows use CIHighlightShadowAdjust, a local tone operator whose
                // neighbourhood is in pixels.
                return options.sharpness <= 0 && options.noiseReduction == 0 && options.highlights >= 0
                    && options.shadows == 0
            case .colorProfile(let options):
                return !options.reduce.isEnabled
            case .rotateFlip(let options):
                return options.effectiveAngle == 0
            case .resize(let options):
                return options.resampling != .nearest && Self.scalesByProportion(options.mode)
            case .crop, .canvas, .perspective, .trim, .watermark, .redact, .condition:
                return false
            }
        }
    }

    private static func scalesByProportion(_ mode: ResizeMode) -> Bool {
        switch mode {
        case .percent, .longestEdge, .shortestEdge, .maxWidth, .maxHeight, .fitBox, .exactWidth, .exactHeight:
            return true
        case .exactSize, .minimum, .physical, .printSheet, .mlEnlarge:
            return false
        }
    }
}

// MARK: Rendering a proxy

extension PreviewRenderer {
    /// A proxy's source: decoded (or scaled from the cached full decode) with `longSide` as its long side.
    struct ProxySource {
        let key: FileKey
        let longSide: Int
        let image: CGImage
        let display: CGImage
    }

    /// A quick stand-in for `render`'s result, flagged `isProxy`: the source decoded near display size (at least
    /// `proxyMinimum`; a JPEG at source / 2^k) and run through the pipeline with its resizes scaled to match, so it
    /// shows the same size as the exact result. Nil when the pipeline isn't scale-invariant
    /// (`Pipeline.isScaleInvariant`), the source is too small for a proxy to help, or anything fails (the exact render
    /// then says why). It never asks for alt text (the model answer belongs to the exact pixels).
    public func renderProxy(item: InputItem, index: Int, pipeline unresolved: Pipeline, mode: OutputMode? = nil,
                            presets: PresetLibrary = .standard) async -> PreviewResult? {
        guard !Task.isCancelled, unresolved.isScaleInvariant else { return nil }
        let resolved = unresolved.withMetadataOverrides(item.metadataOverrides)
            .resolved(forSource: item.source, maxPixels: maxPixels, presets: presets)
        let pipeline = resolved.pipeline
        guard resolved.disposition == .process, pipeline.isScaleInvariant,
              let size = ImageLoader.header(of: item.source)?.uprightSize,
              let longSide = PreviewProxy.decodeLongSide(sourceLongSide: max(size.width, size.height),
                                                         target: max(displayMax, proxyMinimum),
                                                         jpeg: PreviewProxy.isJPEG(item.source)),
              let source = try? proxyImages(for: item.source, longSide: longSide), !Task.isCancelled else { return nil }
        let proxy = PreviewProxy.pipeline(for: pipeline, sourceWidth: size.width, sourceHeight: size.height,
                                          displayMax: displayMax)
        guard let result = try? proxy.apply(to: source.image, focus: caches.context(for: item.source, detector: detector,
                                                                                     enlarger: enlarger)),
              let after = fit(pipeline.asWritten(result, for: pipeline.output.format)), !Task.isCancelled
        else { return nil }
        let output = pipeline.outputSize(sourceWidth: size.width, sourceHeight: size.height)
        var ready = processed(item: item, index: index, resolved: resolved, mode: mode,
                              shown: Shown(before: source.display, after: after, sourceSize: size, outputSize: output))
        ready.isProxy = true
        return ready
    }

    /// The proxy's source at `longSide`: scaled from the full decode when that is cached, else decoded at that size.
    func proxyImages(for url: URL, longSide: Int) throws -> ProxySource {
        let key = FileKey(url)
        if let proxySource, proxySource.key == key, proxySource.longSide == longSide { return proxySource }
        proxySource = nil
        let image: CGImage
        if let full = sourceCache.cached(url, maxPixels: maxPixels)?.image {
            guard let scaled = Self.fit(full, displayMax: longSide) else { throw ConversionError.processingFailed("preview") }
            image = scaled
        } else {
            image = try ImageLoader.load(url, maxPixels: maxPixels, maxLongSide: longSide).image
        }
        guard let display = fit(image) else { throw ConversionError.processingFailed("preview") }
        let decoded = ProxySource(key: key, longSide: longSide, image: image, display: display)
        proxySource = decoded
        return decoded
    }
}
