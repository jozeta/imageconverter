import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a condition can test about a source file. Read from the header (plus, for transparency, a small
/// thumbnail), never from a full decode, so resolving conditions stays cheap for large batches.
public struct ItemFacts: Equatable, Sendable {
    /// Upright size (EXIF orientation applied), as `ImageLoader.load` produces it.
    public var width: Int
    public var height: Int
    public var fileSize: Int
    /// The source type as a writable output format; nil when the app can't write it (e.g. RAW, WebP).
    public var format: OutputFormat?
    /// The source's type identifier (UTI), e.g. `public.jpeg`.
    public var sourceType: String
    /// True when the image has any non-opaque pixel (as far as a ≤ 256 px scan can tell).
    public var hasAlpha: Bool
    public var hasGPS: Bool
    public var make: String?
    public var model: String?

    public init(width: Int, height: Int, fileSize: Int = 0, format: OutputFormat? = nil, sourceType: String = "",
                hasAlpha: Bool = false, hasGPS: Bool = false, make: String? = nil, model: String? = nil) {
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.format = format
        self.sourceType = sourceType
        self.hasAlpha = hasAlpha
        self.hasGPS = hasGPS
        self.make = make
        self.model = model
    }

    /// Long side of the scan that checks a header's alpha claim.
    static let alphaScanSize = 256

    /// Reads the facts of `url`; nil when it isn't a readable image. `scanAlpha: false` trusts the header's
    /// alpha flag (no thumbnail decode), for callers whose conditions don't test transparency. An image over
    /// `maxPixels` is never scanned (ImageIO would decode all of it for the thumbnail): the header decides, and
    /// the batch's own pixel guard fails the file later.
    public static func read(_ url: URL, scanAlpha: Bool = true,
                            maxPixels: Int = ImageLoader.defaultMaxPixels) -> ItemFacts? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else { return nil }
        let upright = ImageHeader(width: width, height: height, properties: properties).uprightSize
        let type = CGImageSourceGetType(source) as String? ?? ""
        let headerAlpha = properties[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        var hasAlpha = headerAlpha
        // PNG, TIFF and HEIC often carry an alpha channel that is fully opaque: look before believing it.
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        if headerAlpha, scanAlpha, scannedTypes.contains(type), !overflow, pixels <= maxPixels {
            hasAlpha = hasTransparentPixel(source) ?? true
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ItemFacts(
            width: upright.width, height: upright.height, fileSize: size, format: writableFormat(for: type),
            sourceType: type, hasAlpha: hasAlpha, hasGPS: !(gps?.isEmpty ?? true),
            make: cleaned(tiff?[kCGImagePropertyTIFFMake as String]),
            model: cleaned(tiff?[kCGImagePropertyTIFFModel as String]))
    }

    private static let scannedTypes: Set<String> = [UTType.png.identifier, UTType.tiff.identifier,
                                                    UTType.heic.identifier, "public.heif"]

    /// Writable formats, read once (the list doesn't change while the app runs).
    private static let writable = OutputFormat.available()

    /// The output format a source type maps to, when the app can write it.
    static func writableFormat(for type: String) -> OutputFormat? {
        guard let format = OutputFormat.allCases.first(where: { $0.utType.identifier == type }) else { return nil }
        return writable.contains(format) ? format : nil
    }

    /// Text from untrusted metadata, trimmed and limited; nil when empty.
    private static func cleaned(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether a ≤ 256 px thumbnail has any pixel with alpha below 255; nil when it can't be decoded.
    private static func hasTransparentPixel(_ source: CGImageSource) -> Bool? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: alphaScanSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let width = thumbnail.width
        let height = thumbnail.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for offset in stride(from: 3, to: width * height * 4, by: 4) where bytes[offset] < 255 { return true }
        return false
    }
}
