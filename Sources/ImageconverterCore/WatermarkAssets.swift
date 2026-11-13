import CoreGraphics
import Foundation

/// The image watermarks of a batch, loaded once so every file in the batch shares them.
public struct WatermarkAssets: @unchecked Sendable {
    // Immutable after `load`, so sharing it between tasks is safe.
    private let images: [String: CGImage]

    public static let empty = WatermarkAssets(images: [:])

    private init(images: [String: CGImage]) {
        self.images = images
    }

    /// Loads each distinct image path used by an enabled watermark step, once, with the pixel guard.
    /// A path that can't be read (missing, a directory, corrupt, too large) is left out.
    public static func load(for pipeline: Pipeline, maxPixels: Int) -> WatermarkAssets {
        var images: [String: CGImage] = [:]
        var tried = Set<String>()
        for step in pipeline.steps where step.isEnabled {
            guard case .watermark(let options) = step.operation,
                  case .image(let watermark) = options.content,
                  tried.insert(watermark.path).inserted else { continue }
            if let image = read(watermark.path, maxPixels: maxPixels) { images[watermark.path] = image }
        }
        return WatermarkAssets(images: images)
    }

    /// The loaded image for `path`, or nil when it wasn't loaded.
    public func image(for path: String) -> CGImage? { images[path] }

    /// How many images were loaded.
    var count: Int { images.count }

    private static func read(_ path: String, maxPixels: Int) -> CGImage? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return try? ImageLoader.load(url, maxPixels: maxPixels).image
    }
}
