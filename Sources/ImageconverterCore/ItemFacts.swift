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

    // Name and location (from the URL).
    /// The file name without its extension.
    public var fileName = ""
    /// Lower-cased, without the dot.
    public var fileExtension = ""
    /// The folder the file is in (full path).
    public var folderPath = ""
    // Dates.
    /// EXIF DateTimeOriginal, else the XMP date created (read as wall clock in the Mac's time zone); nil when
    /// neither is there. The XMP fallback is only read when a condition needs it.
    public var dateTaken: Date?
    public var created: Date?
    public var modified: Date?
    /// Metadata values by field (several for lists such as keywords); text cleaned and limited.
    public var metadata: [MetadataSubject: [String]] = [:]
    // Image.
    /// Bits per color channel, as the header says.
    public var bitsPerComponent: Int?
    public var isFloat = false
    /// `RGB`, `Gray`, `CMYK`, `Lab`.
    public var colorModel: String?
    /// The embedded color profile's name; nil when the file has none.
    public var profileName: String?
    public var dpi: Double?
    /// The EXIF orientation (1 is upright).
    public var exifOrientation = 1
    /// Frames or pages; only counted when a condition asks (1 otherwise).
    public var frameCount = 1
    /// "Now" for "within the last N days"; nil is the current time (tests set it).
    public var now: Date?
    /// On-device image analysis; only what a condition or `{labels}` needs is filled in.
    public var analysis = ImageAnalysis()

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
    /// alpha flag (no thumbnail decode), for callers whose conditions don't test transparency.
    public static func read(_ url: URL, scanAlpha: Bool, maxPixels: Int = ImageLoader.defaultMaxPixels) -> ItemFacts? {
        read(url, needs: scanAlpha ? .all : FactNeeds.all.subtracting(.alphaScan), maxPixels: maxPixels)
    }

    /// Reads the facts of `url` that `needs` asks for beyond the header (the transparency scan, the XMP packet,
    /// the frame count); nil when it isn't a readable image. An image that breaks the decode limits
    /// (`DecodeLimits`, pixel limit `maxPixels`) is never scanned (ImageIO would decode all of it for the
    /// thumbnail): the header decides, and the batch's own guard fails the file later. The analysis parts of
    /// `needs` come from `analysis` (a ≤ 1024 px decode within the same limits, cached per file version).
    public static func read(_ url: URL, needs: FactNeeds = .all, maxPixels: Int = ImageLoader.defaultMaxPixels,
                            analysis: ImageAnalysisCache = .shared) -> ItemFacts? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let header = ImageHeader.read(source) else { return nil }
        let properties = header.properties
        let upright = header.uprightSize
        let type = CGImageSourceGetType(source) as String? ?? ""
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let fileBytes = values?.fileSize
        let size = fileBytes ?? 0
        let headerAlpha = properties[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        var hasAlpha = headerAlpha
        // PNG, TIFF and HEIC often carry an alpha channel that is fully opaque: look before believing it.
        let limits = DecodeLimits.standard.capped(maxPixels: maxPixels)
        if headerAlpha, needs.contains(.alphaScan), scannedTypes.contains(type), size <= limits.maxFileBytes,
           (try? limits.check(source, fileBytes: fileBytes)) != nil {
            hasAlpha = hasTransparentPixel(source) ?? true
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        var facts = ItemFacts(
            width: upright.width, height: upright.height, fileSize: size, format: writableFormat(for: type),
            sourceType: type, hasAlpha: hasAlpha, hasGPS: !(gps?.isEmpty ?? true),
            make: cleaned(tiff?[kCGImagePropertyTIFFMake as String]),
            model: cleaned(tiff?[kCGImagePropertyTIFFModel as String]))
        facts.fileName = url.deletingPathExtension().lastPathComponent
        facts.fileExtension = url.pathExtension.lowercased()
        facts.folderPath = url.deletingLastPathComponent().path
        facts.created = values?.creationDate
        facts.modified = values?.contentModificationDate
        let xmp = needs.contains(.xmp) ? CGImageSourceCopyMetadataAtIndex(source, 0, nil) : nil
        facts.readMetadata(properties, xmp: xmp)
        if needs.contains(.frames) { facts.frameCount = max(1, CGImageSourceGetCount(source)) }
        if !needs.isDisjoint(with: .analysis) {
            facts.analysis = analysis.analysis(of: url, needs: needs, maxPixels: maxPixels)
        }
        return facts
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
    static func cleaned(_ value: Any?) -> String? {
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
