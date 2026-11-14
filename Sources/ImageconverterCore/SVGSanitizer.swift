import Foundation

/// Turns untrusted SVG bytes into a canonical SVG that can only draw shapes, gradients and text:
/// strict UTF-8 → XML parse (no DTDs except the standard SVG one, which is dropped; no entities; depth and size
/// caps) → an allowlist of SVG elements and attributes → simple `<style>` rules inlined as attributes, which pass
/// the same allowlist → reference graph checks → re-serialised. Only the re-serialised text ever reaches AppKit, so encoding,
/// escaping and namespace tricks in the original can't change what is drawn.
enum SVGSanitizer {
    static let svgNamespace = "http://www.w3.org/2000/svg"
    static let xlinkNamespace = "http://www.w3.org/1999/xlink"
    static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"
    static let maxDepth = 64
    static let maxElements = 20_000
    static let maxAttributes = 64
    /// Most element instances the file may expand to once `use`, pattern, mask and clip references are followed.
    static let maxInstances = 10_000

    /// A parsed, validated element.
    final class Element {
        let name: String
        /// Canonical attribute names (`xlink:href` for links), in document order.
        var attributes: [(String, String)] = []
        /// `class` tokens, used only to match `<style>` rules (never written out).
        var classes: [String] = []
        var children: [Node] = []

        init(name: String) { self.name = name }
    }

    enum Node {
        case element(Element)
        case text(String)
    }

    /// Elements refused as embedded or linked content (the rest outside `elements` are unsupported features).
    static let externalElements: Set<String> = ["image", "feImage", "a", "iframe", "embed", "object"]

    static let elements: Set<String> = [
        "svg", "g", "defs", "symbol", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "title", "desc", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "pattern",
    ]
    /// Elements whose character data is kept.
    static let textElements: Set<String> = ["text", "tspan", "title", "desc"]
    /// Elements that may link (to `#id` only).
    static let linkElements: Set<String> = ["use", "linearGradient", "radialGradient", "pattern"]

    static let attributes: Set<String> = [
        "id", "transform", "viewBox", "width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry",
        "fx", "fy", "fr", "d", "points", "fill", "stroke", "opacity", "text-anchor", "dominant-baseline",
        "alignment-baseline", "baseline-shift", "offset", "stop-color", "stop-opacity", "gradientUnits",
        "gradientTransform", "spreadMethod", "patternUnits", "patternContentUnits", "patternTransform", "clip-path",
        "clip-rule", "mask", "maskUnits", "maskContentUnits", "clipPathUnits", "preserveAspectRatio", "version",
        "style", "display", "visibility", "color", "dx", "dy", "rotate", "textLength", "lengthAdjust",
        "letter-spacing", "word-spacing", "pathLength", "vector-effect", "shape-rendering", "paint-order",
        // Illustrator writes this on the root; CoreSVG ignores it.
        "enable-background",
    ]
    /// Attribute families allowed by prefix (`stroke-width`, `fill-opacity`, `font-family`, …).
    static let attributePrefixes = ["stroke-", "fill-", "font-"]

    /// The canonical SVG text for `data`, or a throw: `.watermarkSVGInvalid` for something that isn't
    /// well-formed UTF-8 SVG, `.watermarkSVGExternal` for embedded images and links to other files,
    /// `.watermarkSVGUnsafe` for anything else outside the allowlist.
    static func sanitize(_ data: Data) throws -> Data {
        let text = try decodeUTF8(data)
        let body = try checkProlog(text)
        let (root, styles) = try parse(Data(body.utf8))
        // Inline first, then validate the whole tree: inlined declarations become ordinary attributes.
        try inlineStyles(styles, into: root)
        try checkReferences(root)
        return Data(serialize(root).utf8)
    }

    /// The validated tree and the text of its `<style>` elements, in document order.
    static func parse(_ data: Data) throws -> (root: Element, styles: [String]) {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        let builder = TreeBuilder()
        parser.delegate = builder
        let parsed = parser.parse()
        if let refusal = builder.refusal { throw refusal }
        guard parsed, let root = builder.root else { throw ConversionError.watermarkSVGInvalid }
        return (root, builder.styles)
    }

    // MARK: Validation

    /// The canonical name for an allowed attribute, or a throw. `uri` is the attribute's namespace (nil: none).
    static func validatedAttribute(element: String, name: String, uri: String?, value: String) throws -> String {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch uri {
        case nil:
            if local == "href" { return try link(element: element, value: value) }
            if local == "base" { throw ConversionError.watermarkSVGExternal }
            guard attributes.contains(local) || attributePrefixes.contains(where: local.hasPrefix) else {
                throw ConversionError.watermarkSVGUnsafe
            }
        case xlinkNamespace?:
            guard local == "href" else { throw ConversionError.watermarkSVGUnsafe }
            return try link(element: element, value: value)
        case xmlNamespace? where local == "space":
            return "xml:space"
        case xmlNamespace? where local == "base":
            throw ConversionError.watermarkSVGExternal
        default:
            throw ConversionError.watermarkSVGUnsafe
        }
        try checkValue(value, isStyle: local == "style")
        return local
    }

    private static func link(element: String, value: String) throws -> String {
        guard isLocalReference(value) else { throw ConversionError.watermarkSVGExternal }
        guard linkElements.contains(element) else { throw ConversionError.watermarkSVGUnsafe }
        return "xlink:href"
    }

    /// `#` followed by an XML-name-like id.
    static func isLocalReference(_ value: String) -> Bool {
        guard value.first == "#" else { return false }
        let id = value.dropFirst()
        guard let first = id.first, first.isLetter || first == "_" else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// `url` followed by whitespace and `(` written as `url(`, so every check (and the reference graph) sees it.
    /// Values are stored in this form too.
    static func normalizedURLs(_ value: String) -> String {
        guard value.range(of: #"url\s+\("#, options: [.regularExpression, .caseInsensitive]) != nil else { return value }
        return value.replacingOccurrences(of: #"url\s+\("#, with: "url(", options: [.regularExpression, .caseInsensitive])
    }

    /// Every `url(` (also `url (`) must be exactly `url(#id)`; a style value may not use `@`, `\`, `expression`
    /// or `import`.
    static func checkValue(_ value: String, isStyle: Bool) throws {
        let lower = normalizedURLs(value).lowercased()
        if isStyle {
            if lower.contains("import") { throw ConversionError.watermarkSVGExternal }
            if ["@", "\\", "expression"].contains(where: lower.contains) { throw ConversionError.watermarkSVGUnsafe }
            try checkStyle(lower)
        }
        var rest = Substring(lower)
        while let open = rest.range(of: "url(") {
            guard let close = rest[open.upperBound...].firstIndex(of: ")"),
                  isLocalReference(String(rest[open.upperBound..<close])) else {
                throw ConversionError.watermarkSVGExternal
            }
            rest = rest[rest.index(after: close)...]
        }
        // Outside style, a url() must be the whole value (e.g. fill="url(#g)").
        if !isStyle, lower.contains("url("),
           !(lower.hasPrefix("url(") && lower.hasSuffix(")") && lower.components(separatedBy: "url(").count == 2) {
            throw ConversionError.watermarkSVGUnsafe
        }
    }

    // MARK: Serialising

    static func serialize(_ root: Element) -> String {
        var out = #"<?xml version="1.0" encoding="UTF-8"?>"#
        write(root, isRoot: true, to: &out)
        return out
    }

    private static func write(_ element: Element, isRoot: Bool, to out: inout String) {
        out += "<" + element.name
        if isRoot { out += #" xmlns="\#(svgNamespace)" xmlns:xlink="\#(xlinkNamespace)""# }
        for (name, value) in element.attributes { out += " \(name)=\"\(escape(value, attribute: true))\"" }
        guard !element.children.isEmpty else {
            out += "/>"
            return
        }
        out += ">"
        for child in element.children {
            switch child {
            case .element(let nested): write(nested, isRoot: false, to: &out)
            case .text(let text): out += escape(text, attribute: false)
            }
        }
        out += "</" + element.name + ">"
    }

    static func escape(_ text: String, attribute: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\t" where attribute, "\n" where attribute, "\r" where attribute: out += "&#\(scalar.value);"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
