import CoreGraphics
import Foundation
import ImageIO

/// A decoded, upright image plus the source's metadata.
public struct LoadedImage: @unchecked Sendable {
    public let image: CGImage
    /// The source's property dictionary, with orientation reset to 1 (already applied to `image`).
    public let properties: [String: Any]
    /// The source's metadata view (XMP plus ImageIO's EXIF/IPTC mirrors); nil when it has none or it
    /// wasn't asked for.
    public let metadata: CGImageMetadata?
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

    /// The first frame's size and property dictionary, read from the header only (no decode, no limits:
    /// for information such as names and sizes). Nil if unreadable.
    public static func header(of url: URL) -> ImageHeader? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateWithURL(url as CFURL, options).flatMap(ImageHeader.read)
    }

    /// Loads the first frame of `url`, rotated upright according to its EXIF orientation.
    /// Throws before decoding when the file breaks `limits` (capped at `maxPixels`): too many pixels, a side
    /// too long, too much memory, too large a file or a likely decompression bomb. With `maxLongSide`, a
    /// larger image is downsampled so its longer side fits. `includeMetadata` also reads the XMP view
    /// (only the Metadata step needs it). `lowMemory` leaves the decode to ImageIO's first draw instead of
    /// decoding into a cached buffer up front (the batch's retry and low-memory mode).
    public static func load(_ url: URL, maxPixels: Int = defaultMaxPixels, limits: DecodeLimits = .standard,
                            maxLongSide: Int? = nil, includeMetadata: Bool = false,
                            lowMemory: Bool = false) throws -> LoadedImage {
        let (source, header) = try limits.capped(maxPixels: maxPixels).open(url, decodeLongSide: maxLongSide)
        var properties = header.properties
        let (width, height) = (header.width, header.height)

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxLongSide.map { max(1, $0) } ?? Int.max),
            kCGImageSourceShouldCacheImmediately: !lowMemory,
        ] as CFDictionary
        // The header was fine, so a failure here is the pixels (damaged data, or no memory): worth a retry.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ConversionError.decodeFailed
        }

        properties[kCGImagePropertyOrientation as String] = 1
        let tiffKey = kCGImagePropertyTIFFDictionary as String
        if var tiff = properties[tiffKey] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[tiffKey] = tiff
        }
        return LoadedImage(image: image, properties: properties,
                           metadata: includeMetadata ? CGImageSourceCopyMetadataAtIndex(source, 0, nil) : nil)
    }
}

extension ImageLoader {
    /// A thumbnail of `url` with its longer side at most `maxPixelSize`, upright; nil when the file is unreadable
    /// or breaks `limits` (ImageIO may decode the whole image to make it). `allowEmbedded` (the filmstrip and the
    /// watermark chip only): the file's embedded thumbnail may be used (a 48 MP HEIC's takes 3 ms instead of 100);
    /// one smaller than asked for, or of another shape than the image (it may show the uncropped photo), is ignored
    /// and the thumbnail is made from the image. Analysis, redaction and alt text copies always come from the image.
    public static func thumbnail(of url: URL, maxPixelSize: Int, limits: DecodeLimits = .standard,
                                 allowEmbedded: Bool = false) -> CGImage? {
        guard let (source, header) = try? limits.open(url, decodeLongSide: max(1, maxPixelSize)) else { return nil }
        let size = max(1, maxPixelSize)
        let options = thumbnailOptions(maxPixelSize: size, allowEmbedded: allowEmbedded)
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard allowEmbedded, !embeddedThumbnailFits(width: thumbnail.width, height: thumbnail.height,
                                                    image: header.uprightSize, maxPixelSize: size) else { return thumbnail }
        return CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                   thumbnailOptions(maxPixelSize: size, allowEmbedded: false) as CFDictionary)
    }

    /// True when a `width` x `height` thumbnail can stand for an `image`-sized picture asked for at `maxPixelSize`:
    /// at least the asked size (or the image's, if smaller) and the same shape within 2 %.
    static func embeddedThumbnailFits(width: Int, height: Int, image: (width: Int, height: Int), maxPixelSize: Int) -> Bool {
        guard width > 0, height > 0, image.width > 0, image.height > 0 else { return false }
        guard max(width, height) >= min(maxPixelSize, max(image.width, image.height)) else { return false }
        let aspect = Double(width) / Double(height)
        let expected = Double(image.width) / Double(image.height)
        return abs(aspect - expected) / expected <= 0.02
    }

    static func thumbnailOptions(maxPixelSize: Int, allowEmbedded: Bool) -> [CFString: Any] {
        [
            allowEmbedded ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
    }
}
