import AppKit
import CoreGraphics
import Foundation

/// Turns an SVG watermark into a bitmap. SVG files are untrusted: the file is size-checked and its text
/// scanned before AppKit ever sees it, and anything that could reach outside the file (links, imports,
/// scripts, foreign objects, entity definitions) is refused. Nothing is ever fetched.
public enum SVGRasterizer {
    /// Largest SVG file accepted.
    public static let maxFileSize = 1_048_576
    /// Longest side of the rendered bitmap.
    public static let maxLongSide = 4096

    /// Whether `url` names an SVG file (by extension).
    public static func isSVG(_ url: URL) -> Bool { url.pathExtension.lowercased() == "svg" }

    /// Renders the SVG at `url` with its long side at `maxLongSide` px (fewer when that would exceed
    /// `maxPixels`), keeping its aspect ratio, on a transparent background.
    public static func rasterize(url: URL, maxPixels: Int = ImageLoader.defaultMaxPixels) throws -> CGImage {
        let data = try readLimited(url)
        try check(data)
        return try render(data, maxPixels: maxPixels)
    }

    /// Opens without following links or blocking, refuses non-regular files, reads at most the limit + 1 byte.
    static func readLimited(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ConversionError.watermarkImageUnreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ConversionError.watermarkImageUnreadable
        }
        guard info.st_size <= maxFileSize else { throw ConversionError.watermarkSVGTooLarge }
        guard let data = try? handle.read(upToCount: maxFileSize + 1) else {
            throw ConversionError.watermarkImageUnreadable
        }
        guard data.count <= maxFileSize else { throw ConversionError.watermarkSVGTooLarge }
        return data
    }

    /// Refuses SVG text that isn't UTF-8 SVG, or that could load or run anything. The text is compared
    /// lowercased with whitespace and quotes removed, so spacing and quoting tricks don't hide a link.
    static func check(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw ConversionError.watermarkImageUnreadable }
        let compact = String(text.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\"" && $0 != "'"
        }.map(Character.init))
        guard compact.contains("<svg") else { throw ConversionError.watermarkImageUnreadable }
        let forbidden = ["<script", "<foreignobject", "@import", "<!entity", "<iframe", "<embed", "<object",
                         "<?xml-stylesheet", "javascript:"]
        if forbidden.contains(where: compact.contains) { throw ConversionError.watermarkSVGUnsafe }
        // Every link and CSS url() must point inside the file (#id) or be an inline raster image.
        for marker in ["href=", "url("] where !referencesAreLocal(compact, after: marker) {
            throw ConversionError.watermarkSVGUnsafe
        }
    }

    /// True when every occurrence of `marker` in `text` is followed by `#` or an inline PNG/JPEG/GIF.
    private static func referencesAreLocal(_ text: String, after marker: String) -> Bool {
        var rest = Substring(text)
        while let range = rest.range(of: marker) {
            let value = rest[range.upperBound...]
            let local = value.hasPrefix("#") || value.isEmpty
                || ["data:image/png", "data:image/jpeg", "data:image/jpg", "data:image/gif"].contains {
                    value.hasPrefix($0)
                }
            guard local else { return false }
            rest = rest[range.upperBound...]
        }
        return true
    }

    private static func render(_ data: Data, maxPixels: Int) throws -> CGImage {
        guard let image = NSImage(data: data) else { throw ConversionError.watermarkImageUnreadable }
        // NSImage sniffs the data: only accept it when AppKit really read it as SVG.
        guard image.representations.contains(where: { String(describing: type(of: $0)).contains("SVG") }) else {
            throw ConversionError.watermarkSVGUnsupported
        }
        let natural = image.size
        guard natural.width.isFinite, natural.height.isFinite, natural.width > 0, natural.height > 0 else {
            throw ConversionError.watermarkImageUnreadable
        }
        var scale = CGFloat(maxLongSide) / max(natural.width, natural.height)
        let pixels = Double(natural.width * scale) * Double(natural.height * scale)
        if pixels > Double(max(1, maxPixels)) { scale *= CGFloat((Double(max(1, maxPixels)) / pixels).squareRoot()) }
        let width = max(1, Int((natural.width * scale).rounded()))
        let height = max(1, Int((natural.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.watermarkImageUnreadable
        }
        ctx.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = ctx.makeImage() else { throw ConversionError.watermarkImageUnreadable }
        return result
    }
}
