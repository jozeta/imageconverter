import Foundation

/// The bytes and the prolog: strict UTF-8, the XML declaration, and the one doctype that is allowed.
extension SVGSanitizer {
    /// Strict UTF-8 (a UTF-8 BOM is dropped); other BOMs and NUL bytes are refused.
    static func decodeUTF8(_ data: Data) throws -> String {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let foreignBOMs: [[UInt8]] = [[0xFE, 0xFF], [0xFF, 0xFE], [0x2B, 0x2F, 0x76], [0x00, 0x00, 0xFE, 0xFF]]
        guard !foreignBOMs.contains(where: { bytes.starts(with: $0) }), !bytes.contains(0),
              let text = String(data: Data(bytes), encoding: .utf8) else {
            throw ConversionError.watermarkSVGInvalid
        }
        return text
    }

    /// An XML declaration may only declare UTF-8; entity declarations are refused anywhere, and so is any doctype
    /// except one standard SVG doctype in the prolog, which is removed. Returns the text to parse.
    /// Each check is one linear pass.
    static func checkProlog(_ text: String) throws -> String {
        let lower = text.lowercased()
        if lower.contains("<!entity") { throw ConversionError.watermarkSVGUnsafe }
        let body = lower.contains("<!doctype") ? try strippingStandardDoctype(text) : text
        // `<?xml` followed by whitespace is the declaration (`<?xml-stylesheet` is a PI the parser refuses).
        guard lower.hasPrefix("<?xml"), lower.dropFirst(5).first?.isWhitespace == true else { return body }
        guard let end = lower.range(of: "?>"),
              let pseudo = declarationAttributes(lower[lower.index(lower.startIndex, offsetBy: 5)..<end.lowerBound]) else {
            throw ConversionError.watermarkSVGInvalid
        }
        if let encoding = pseudo["encoding"], encoding != "utf-8", encoding != "utf8" {
            throw ConversionError.watermarkSVGUnsafe
        }
        return body
    }

    /// The public doctypes design tools write (Illustrator: 1.0 and 1.1), whitespace collapsed.
    static let standardDoctypes: Set<String> = [
        #"svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd""#,
        #"svg PUBLIC "-//W3C//DTD SVG 1.1 Basic//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11-basic.dtd""#,
        #"svg PUBLIC "-//W3C//DTD SVG 1.1 Tiny//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11-tiny.dtd""#,
        #"svg PUBLIC "-//W3C//DTD SVG 1.0//EN" "http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd""#,
        #"svg PUBLIC "-//W3C//DTD SVG 20010904//EN" "http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd""#,
    ]

    /// `text` without its doctype, when that is exactly one standard SVG doctype (no internal subset) after only
    /// the XML declaration, comments and whitespace; otherwise a refusal.
    static func strippingStandardDoctype(_ text: String) throws -> String {
        guard let start = text.range(of: "<!DOCTYPE"), text[start.upperBound...].first.map(isXMLSpace) == true,
              let end = text[start.upperBound...].firstIndex(of: ">") else { throw ConversionError.watermarkSVGUnsafe }
        // Only XML whitespace separates the parts; any other character (e.g. a no-break space) makes it no match.
        let declaration = text[start.upperBound..<end].split(whereSeparator: isXMLSpace).joined(separator: " ")
        let rest = text[text.index(after: end)...]
        guard standardDoctypes.contains(declaration), isProlog(text[..<start.lowerBound]),
              !rest.lowercased().contains("<!doctype") else { throw ConversionError.watermarkSVGUnsafe }
        return String(text[..<start.lowerBound]) + rest
    }

    /// Space, tab, CR or LF (a CR LF pair is one `Character`).
    static func isXMLSpace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { [" ", "\t", "\r", "\n"].contains($0) }
    }

    /// True when `prefix` is only whitespace, an XML declaration and comments.
    private static func isProlog(_ prefix: Substring) -> Bool {
        var rest = prefix.drop { $0.isWhitespace }
        if rest.hasPrefix("<?xml") {
            guard let close = rest.range(of: "?>") else { return false }
            rest = rest[close.upperBound...]
        }
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.isEmpty { return true }
            guard rest.hasPrefix("<!--"), let close = rest.range(of: "-->") else { return false }
            rest = rest[close.upperBound...]
        }
    }

    /// The XML declaration's `name="value"` pairs (either quote), or nil when it isn't well-formed.
    static func declarationAttributes(_ text: Substring) -> [String: String]? {
        var pairs: [String: String] = [:]
        var rest = text.drop { $0.isWhitespace }
        while !rest.isEmpty {
            let name = rest.prefix { $0.isLetter }
            guard !name.isEmpty else { return nil }
            rest = rest.dropFirst(name.count).drop { $0.isWhitespace }
            guard rest.first == "=" else { return nil }
            rest = rest.dropFirst().drop { $0.isWhitespace }
            guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
            rest = rest.dropFirst()
            guard let close = rest.firstIndex(of: quote) else { return nil }
            pairs[String(name)] = String(rest[..<close])
            rest = rest[rest.index(after: close)...].drop { $0.isWhitespace }
        }
        return pairs
    }
}
