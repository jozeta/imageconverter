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
    /// The largest thumbnail made from the file's embedded thumbnail when it has one (the filmstrip and the
    /// watermark chip): a 48 MP HEIC's takes 3 ms instead of 100. Larger copies feed analysis, redaction and alt
    /// text, so they always come from the image itself (an embedded thumbnail may be small or stale).
    static let embeddedThumbnailMaxSize = 512

    /// A thumbnail of `url` with its longer side at most `maxPixelSize`, upright; nil when the file is unreadable
    /// or breaks `limits` (ImageIO may decode the whole image to make it). Up to `embeddedThumbnailMaxSize` the
    /// file's embedded thumbnail is used when it is big enough; a smaller one is made from the image again.
    public static func thumbnail(of url: URL, maxPixelSize: Int, limits: DecodeLimits = .standard) -> CGImage? {
        guard let (source, header) = try? limits.open(url, decodeLongSide: max(1, maxPixelSize)) else { return nil }
        let size = max(1, maxPixelSize)
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize: size) as CFDictionary)
        else { return nil }
        let expected = min(size, max(header.width, header.height))
        guard size <= embeddedThumbnailMaxSize, max(thumbnail.width, thumbnail.height) < expected else { return thumbnail }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize: size, embedded: false) as CFDictionary)
    }

    /// `embedded`: allow the file's embedded thumbnail (only up to `embeddedThumbnailMaxSize`).
    static func thumbnailOptions(maxPixelSize: Int, embedded: Bool = true) -> [CFString: Any] {
        let fromImage = embedded && maxPixelSize <= embeddedThumbnailMaxSize
            ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways
        return [
            fromImage: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
    }
}
