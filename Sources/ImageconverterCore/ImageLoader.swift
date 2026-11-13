import CoreGraphics
import Foundation
import ImageIO

/// A decoded, upright image plus the source's metadata.
public struct LoadedImage: @unchecked Sendable {
    public let image: CGImage
    /// The source's property dictionary, with orientation reset to 1 (already applied to `image`).
    public let properties: [String: Any]
}

public enum ImageLoader {
    public static let defaultMaxPixels = 250_000_000

    /// Loads the first frame of `url`, rotated upright according to its EXIF orientation.
    /// Throws `.tooLarge` before decoding when the image exceeds `maxPixels`.
    public static func load(_ url: URL, maxPixels: Int = defaultMaxPixels) throws -> LoadedImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else {
            throw ConversionError.unreadable
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        if overflow || pixels > maxPixels {
            throw ConversionError.tooLarge(pixels: overflow ? Int.max : pixels)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ConversionError.unreadable
        }

        properties[kCGImagePropertyOrientation as String] = 1
        let tiffKey = kCGImagePropertyTIFFDictionary as String
        if var tiff = properties[tiffKey] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[tiffKey] = tiff
        }
        return LoadedImage(image: image, properties: properties)
    }
}
