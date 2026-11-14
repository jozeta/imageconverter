import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

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

    /// Refuses SVG text that isn't UTF-8 SVG, or that could load or run anything. Character references and
    /// CSS escapes are decoded first, then the text is compared lowercased with whitespace and quotes removed,
    /// so encoding, spacing and quoting tricks don't hide a link.
    static func check(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), startsWithSVGElement(text) else {
            throw ConversionError.watermarkImageUnreadable
        }
        let decoded = decodeCSSEscapes(decodeCharacterReferences(text))
        let compact = String(decoded.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\"" && $0 != "'"
        }.map(Character.init))
        let forbidden = ["<script", "<foreignobject", "@import", "<!entity", "<iframe", "<embed", "<object",
                         "<?xml-stylesheet", "javascript:", "data:",
                         // Animation that rewrites a link at run time.
                         "attributename=href", "attributename=xlink:href"]
        if forbidden.contains(where: compact.contains) { throw ConversionError.watermarkSVGUnsafe }
        // Every link and CSS url() must point inside the file (#id).
        for marker in ["href=", "url("] where !referencesAreLocal(compact, after: marker) {
            throw ConversionError.watermarkSVGUnsafe
        }
    }

    /// True when the first element, after an optional BOM, XML declaration, comments and doctype, is `<svg`.
    static func startsWithSVGElement(_ text: String) -> Bool {
        var rest = Substring(text)
        if rest.hasPrefix("\u{FEFF}") { rest = rest.dropFirst() }
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.hasPrefix("<?") {
                guard let end = rest.range(of: "?>") else { return false }
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { return false }
                rest = rest[end.upperBound...]
            } else if rest.prefix(9).lowercased() == "<!doctype" {
                // An internal subset ends with "]>", a plain doctype with ">".
                let closing = rest.contains("[") && (rest.firstIndex(of: "[") ?? rest.endIndex)
                    < (rest.firstIndex(of: ">") ?? rest.endIndex) ? "]>" : ">"
                guard let end = rest.range(of: closing) else { return false }
                rest = rest[end.upperBound...]
            } else {
                guard rest.prefix(4).lowercased() == "<svg" else { return false }
                let next = rest.dropFirst(4).first
                return next == nil || next == ">" || next == "/" || next?.isWhitespace == true
            }
        }
    }

    /// `&#104;` / `&#x68;` and the five predefined entities, decoded (unknown or invalid ones are kept).
    static func decodeCharacterReferences(_ text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semi = after.prefix(12).firstIndex(of: ";") else {
                out.append("&")
                rest = after
                continue
            }
            let body = after[..<semi].lowercased()
            var scalar: Unicode.Scalar?
            if body.hasPrefix("#x") {
                scalar = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
            } else if body.hasPrefix("#") {
                scalar = UInt32(body.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init)
            }
            if let scalar {
                out.unicodeScalars.append(scalar)
            } else if let value = named[body] {
                out += value
            } else {
                out += "&" + after[..<semi] + ";"
            }
            rest = after[after.index(after: semi)...]
        }
        return out + rest
    }

    /// CSS escapes: `\72` (1–6 hex digits, one optional space after) becomes the character, `\x` becomes `x`.
    static func decodeCSSEscapes(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\", index + 1 < scalars.count else {
                out.append(scalar)
                index += 1
                continue
            }
            var hex = ""
            var next = index + 1
            while next < scalars.count, hex.count < 6, scalars[next].properties.isASCIIHexDigit {
                hex.unicodeScalars.append(scalars[next])
                next += 1
            }
            if let value = UInt32(hex, radix: 16), !hex.isEmpty {
                out.append(Unicode.Scalar(value) ?? "\u{FFFD}")
                if next < scalars.count, scalars[next] == " " { next += 1 }
                index = next
            } else {
                out.append(scalars[index + 1])
                index += 2
            }
        }
        return String(out)
    }

    /// True when every occurrence of `marker` in `text` is followed by `#` (a reference inside the file).
    private static func referencesAreLocal(_ text: String, after marker: String) -> Bool {
        var rest = Substring(text)
        while let range = rest.range(of: marker) {
            let value = rest[range.upperBound...]
            guard value.hasPrefix("#") || value.isEmpty else { return false }
            rest = value
        }
        return true
    }

    private static func render(_ data: Data, maxPixels: Int) throws -> CGImage {
        // The content is known to be SVG (`check`); whether AppKit can draw it is a property of this macOS.
        guard NSImage.imageTypes.contains(UTType.svg.identifier) else { throw ConversionError.watermarkSVGUnsupported }
        guard let image = NSImage(data: data), !image.representations.isEmpty else {
            throw ConversionError.watermarkImageUnreadable
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
