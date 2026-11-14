import CoreGraphics
import Foundation
import ImageIO

/// The one gate before any pixels of an untrusted file are decoded: the batch, the preview, thumbnails, the
/// size estimate, the quality ladder, watermark images and SVG rasters all check here first. Everything is
/// decided from the file size and the first frame's header; declared sizes are never trusted beyond these
/// hard limits.
public struct DecodeLimits: Equatable, Sendable {
    public var maxPixels: Int
    /// Longest side in pixels (65 535, the largest side most decoders and Core Graphics handle).
    public var maxSide: Int
    /// Memory the decoded image and its working copies may need: pixels × bytes per pixel × 1.5.
    public var maxDecodedBytes: Int
    public var maxFileBytes: Int

    /// Only the first frame is ever inspected or decoded.
    public static let maxFramesInspected = 1
    /// Decoded size is multiplied by this for the working copies a pipeline makes.
    static let workingCopyFactor = 1.5
    /// Below this many pixels a tiny file is never suspicious.
    static let bombMinimumPixels = 50_000_000
    /// A file under 1/`bombRatio` of its decoded size is suspicious.
    static let bombRatio = 1000
    /// Formats whose ImageIO decoders scale while decoding (JPEG's DCT scaling, HEIC/HEIF's tiles and
    /// thumbnails), so a downsampled decode only needs memory for the reduced size. AVIF and the rest (PNG,
    /// TIFF, GIF, BMP, RAW, ...) may hold the full image while decoding.
    public static let reducedSizeDecodeTypes: Set<String> = ["public.jpeg", "public.heic", "public.heif"]

    public static let standard = DecodeLimits()

    /// min(4 GiB, a quarter of the Mac's memory).
    public static var defaultMaxDecodedBytes: Int {
        min(4 << 30, Int(clamping: ProcessInfo.processInfo.physicalMemory / 4))
    }

    public init(maxPixels: Int = 250_000_000, maxSide: Int = 65_535,
                maxDecodedBytes: Int = DecodeLimits.defaultMaxDecodedBytes, maxFileBytes: Int = 2 << 30) {
        self.maxPixels = maxPixels
        self.maxSide = maxSide
        self.maxDecodedBytes = maxDecodedBytes
        self.maxFileBytes = maxFileBytes
    }

    /// These limits with a pixel limit no higher than `maxPixels` (callers that pass their own pixel cap).
    public func capped(maxPixels limit: Int) -> DecodeLimits {
        var copy = self
        copy.maxPixels = min(maxPixels, limit)
        return copy
    }

    // MARK: Checks

    /// Checks the file at `url` (size, then the first frame's header) and returns that header.
    @discardableResult
    public func check(_ url: URL) throws -> ImageHeader {
        try open(url).header
    }

    /// Whether `url` passes `check`.
    public func allows(_ url: URL) -> Bool { (try? check(url)) != nil }

    /// Opens `url` without caching and checks it; the source is only returned when it may be decoded.
    /// `decodeLongSide`: the longest side the caller decodes at (a downsampled load or a thumbnail), if smaller.
    func open(_ url: URL, decodeLongSide: Int? = nil) throws -> (source: CGImageSource, header: ImageHeader) {
        let fileBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let fileBytes, fileBytes > maxFileBytes { throw ConversionError.fileTooLarge(limit: maxFileBytes) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { throw ConversionError.unreadable }
        return (source, try check(source, fileBytes: fileBytes, decodeLongSide: decodeLongSide))
    }

    /// Checks the first frame of `source`. `fileBytes` nil (data the app encoded itself) skips the
    /// decompression-bomb heuristic; the hard limits always apply. See the pure `check` for `decodeLongSide`.
    @discardableResult
    public func check(_ source: CGImageSource, fileBytes: Int?, decodeLongSide: Int? = nil) throws -> ImageHeader {
        guard let header = ImageHeader.read(source) else { throw ConversionError.unreadable }
        try check(width: header.width, height: header.height, bytesPerPixel: Self.bytesPerPixel(header.properties),
                  fileBytes: fileBytes, type: CGImageSourceGetType(source) as String? ?? "",
                  decodeLongSide: decodeLongSide)
        return header
    }

    /// The rules, in order: a readable size, the side limit, the decompression-bomb heuristic, the pixel limit,
    /// then memory. Side, pixels and the bomb heuristic always use the declared size. The memory limit uses the
    /// reduced size when the decode is downsampled (`decodeLongSide` below the long side) and the format decodes
    /// at reduced size (`reducedSizeDecodeTypes`); otherwise the full size.
    ///
    /// The bomb heuristic (over 50 MP, file under 1/1000 of the decoded size) only refuses an image that also
    /// breaks a hard limit (pixels or memory at full size): flat colour legitimately compresses that well in
    /// many formats, so within the limits it is allowed, and beyond them the tiny file gets the clearer reason.
    public func check(width: Int, height: Int, bytesPerPixel: Int, fileBytes: Int?, type: String,
                      decodeLongSide: Int? = nil) throws {
        guard width > 0, height > 0 else { throw ConversionError.unreadable }
        let side = max(width, height)
        if side > maxSide { throw ConversionError.sideTooLong(side: side, limit: maxSide) }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let decoded = Double(width) * Double(height) * Double(max(1, bytesPerPixel))
        let needed = decoded * Self.workingCopyFactor
        let breaksHardLimit = overflow || pixels > maxPixels || needed > Double(maxDecodedBytes)
        if let fileBytes, breaksHardLimit, overflow || pixels > Self.bombMinimumPixels,
           Double(max(0, fileBytes)) * Double(Self.bombRatio) < decoded {
            throw ConversionError.suspectedDecompressionBomb
        }
        if overflow || pixels > maxPixels { throw ConversionError.tooLarge(pixels: overflow ? Int.max : pixels) }
        var decodedNeeded = needed
        if let decodeLongSide, decodeLongSide > 0, decodeLongSide < side, Self.reducedSizeDecodeTypes.contains(type) {
            let scale = Double(decodeLongSide) / Double(side)
            let reducedWidth = max(1, (Double(width) * scale).rounded(.up))
            let reducedHeight = max(1, (Double(height) * scale).rounded(.up))
            decodedNeeded = reducedWidth * reducedHeight * Double(max(1, bytesPerPixel)) * Self.workingCopyFactor
        }
        if decodedNeeded > Double(maxDecodedBytes) { throw ConversionError.needsTooMuchMemory(limit: maxDecodedBytes) }
    }

    /// Bytes per pixel of the decoded image, from the header's depth (bits per sample) and channels. Working
    /// copies are RGBA, so never fewer than four channels; samples over 16 bits count as 32-bit float.
    public static func bytesPerPixel(_ properties: [String: Any]) -> Int {
        let depth = properties[kCGImagePropertyDepth as String] as? Int ?? 8
        let bytesPerSample = depth <= 8 ? 1 : depth <= 16 ? 2 : 4
        let model = properties[kCGImagePropertyColorModel as String] as? String
        let colours = model == (kCGImagePropertyColorModelCMYK as String) ? 4 : 3
        let alpha = properties[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        return max(4, colours + (alpha ? 1 : 0)) * bytesPerSample
    }
}

extension ImageHeader {
    /// The first frame's size and properties; nil when the header has no usable size.
    static func read(_ source: CGImageSource) -> ImageHeader? {
        guard CGImageSourceGetCount(source) >= DecodeLimits.maxFramesInspected,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else { return nil }
        return ImageHeader(width: width, height: height, properties: properties)
    }
}
