import CoreGraphics
import Foundation

/// The image watermarks of a batch, loaded once so every file in the batch shares them.
public struct WatermarkAssets: @unchecked Sendable {
    // Immutable after `load`, so sharing it between tasks is safe.
    private let images: [String: CGImage]
    /// Why a path couldn't be loaded, when there is a more specific reason than "couldn't read".
    private let errors: [String: ConversionError]

    /// Longest side a watermark image is kept at; larger ones are downsampled on load.
    static let maxLongSide = 4096

    public static let empty = WatermarkAssets(images: [:], errors: [:])

    private init(images: [String: CGImage], errors: [String: ConversionError]) {
        self.images = images
        self.errors = errors
    }

    /// Loads each distinct image path used by an enabled watermark step, once, with the pixel guard.
    /// A path that can't be read (missing, a directory, corrupt, too large, an unsafe SVG) is left out, with
    /// its reason. SVG files are rasterised here (see `SVGRasterizer`).
    public static func load(for pipeline: Pipeline, maxPixels: Int) -> WatermarkAssets {
        var images: [String: CGImage] = [:]
        var errors: [String: ConversionError] = [:]
        var tried = Set<String>()
        for step in pipeline.steps where step.isEnabled {
            guard case .watermark(let options) = step.operation,
                  case .image(let watermark) = options.content,
                  tried.insert(watermark.path).inserted else { continue }
            switch read(watermark.path, maxPixels: maxPixels) {
            case .success(let image): images[watermark.path] = image
            case .failure(let error): errors[watermark.path] = error
            }
        }
        return WatermarkAssets(images: images, errors: errors)
    }

    /// The loaded image for `path`, or nil when it wasn't loaded.
    public func image(for path: String) -> CGImage? { images[path] }

    /// True when an enabled image-watermark step uses a path that wasn't loaded.
    public func hasMissing(for pipeline: Pipeline) -> Bool {
        pipeline.steps.contains { step in
            guard step.isEnabled, case .watermark(let options) = step.operation,
                  case .image(let watermark) = options.content else { return false }
            return images[watermark.path] == nil
        }
    }

    /// Why the first enabled image-watermark step's image wasn't loaded, or nil when nothing is missing.
    public func missingError(for pipeline: Pipeline) -> ConversionError? {
        for step in pipeline.steps where step.isEnabled {
            guard case .watermark(let options) = step.operation, case .image(let watermark) = options.content,
                  images[watermark.path] == nil else { continue }
            return errors[watermark.path] ?? .watermarkImageUnreadable
        }
        return nil
    }

    /// How many images were loaded.
    var count: Int { images.count }

    private static func read(_ path: String, maxPixels: Int) -> Result<CGImage, ConversionError> {
        guard !path.isEmpty else { return .failure(.watermarkImageUnreadable) }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return .failure(.watermarkImageUnreadable) }
        do {
            if SVGRasterizer.isSVG(url) { return .success(try SVGRasterizer.rasterize(url: url, maxPixels: maxPixels)) }
            return .success(try ImageLoader.load(url, maxPixels: maxPixels, maxLongSide: maxLongSide).image)
        } catch let error as ConversionError {
            // The pixel guard and decode errors describe the source; for a watermark say which image it is.
            switch error {
            case .watermarkSVGUnsafe, .watermarkSVGTooLarge, .watermarkSVGUnsupported: return .failure(error)
            default: return .failure(.watermarkImageUnreadable)
            }
        } catch {
            return .failure(.watermarkImageUnreadable)
        }
    }
}
