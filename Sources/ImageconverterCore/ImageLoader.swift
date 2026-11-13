import CoreGraphics
import Foundation
import ImageIO

/// A decoded, upright image plus the source's metadata.
public struct LoadedImage: @unchecked Sendable {
    public let image: CGImage
    /// The source's property dictionary, with orientation reset to 1 (already applied to `image`).
    public let properties: [String: Any]
}

/// A file's first-frame size and properties, without decoding pixels.
public struct ImageHeader: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let properties: [String: Any]

    /// The size after the EXIF orientation is applied (orientations 5-8 swap width and height),
    /// which is what `ImageLoader.load` produces.
    public var uprightSize: (width: Int, height: Int) {
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }
}

public enum ImageLoader {
    public static let defaultMaxPixels = 250_000_000

    /// The pixel count of the first frame, read from the header only. Nil if unreadable.
    public static func pixelCount(of url: URL) -> Int? {
        guard let size = pixelSize(of: url) else { return nil }
        let (pixels, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        return overflow ? Int.max : pixels
    }

    /// The upright pixel size of the first frame (EXIF orientation applied), read from the header
    /// only. Nil if unreadable.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        header(of: url)?.uprightSize
    }

    /// The first frame's size and property dictionary, read from the header only (no decode).
    /// Nil if unreadable.
    public static func header(of url: URL) -> ImageHeader? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else { return nil }
        return ImageHeader(width: width, height: height, properties: properties)
    }

    /// Loads the first frame of `url`, rotated upright according to its EXIF orientation.
    /// Throws `.tooLarge` before decoding when the image exceeds `maxPixels`. With `maxLongSide`, a
    /// larger image is downsampled so its longer side fits.
    public static func load(_ url: URL, maxPixels: Int = defaultMaxPixels,
                            maxLongSide: Int? = nil) throws -> LoadedImage {
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
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxLongSide.map { max(1, $0) } ?? Int.max),
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
