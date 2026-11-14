import Foundation

/// Turns untrusted SVG bytes into a canonical SVG that can only draw shapes, gradients and text:
/// strict UTF-8 → XML parse (no DTDs, no external entities, depth and size caps) → an allowlist of SVG
/// elements and attributes → re-serialised. Only the re-serialised text ever reaches AppKit, so encoding,
/// escaping and namespace tricks in the original can't change what is drawn.
enum SVGSanitizer {
    static let svgNamespace = "http://www.w3.org/2000/svg"
    static let xlinkNamespace = "http://www.w3.org/1999/xlink"
    static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"
    static let maxDepth = 64
    static let maxElements = 20_000

    /// A parsed, validated element.
    final class Element {
        let name: String
        /// Canonical attribute names (`xlink:href` for links), in document order.
        var attributes: [(String, String)] = []
        var children: [Node] = []

        init(name: String) { self.name = name }
    }

    enum Node {
        case element(Element)
        case text(String)
    }

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
    ]
    /// Attribute families allowed by prefix (`stroke-width`, `fill-opacity`, `font-family`, …).
    static let attributePrefixes = ["stroke-", "fill-", "font-"]

    /// The canonical SVG text for `data`, or a throw: `.watermarkImageUnreadable` for something that isn't
    /// well-formed UTF-8 SVG, `.watermarkSVGUnsafe` for anything outside the allowlist.
    static func sanitize(_ data: Data) throws -> Data {
        let text = try decodeUTF8(data)
        try checkProlog(text)
        let root = try parse(Data(text.utf8))
        return Data(serialize(root).utf8)
    }

    /// Strict UTF-8 (a UTF-8 BOM is dropped); other BOMs and NUL bytes are refused.
    static func decodeUTF8(_ data: Data) throws -> String {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let foreignBOMs: [[UInt8]] = [[0xFE, 0xFF], [0xFF, 0xFE], [0x2B, 0x2F, 0x76], [0x00, 0x00, 0xFE, 0xFF]]
        guard !foreignBOMs.contains(where: { bytes.starts(with: $0) }), !bytes.contains(0),
              let text = String(data: Data(bytes), encoding: .utf8) else {
            throw ConversionError.watermarkImageUnreadable
        }
        return text
    }

    /// An XML declaration may only declare UTF-8; doctypes and entity declarations are refused anywhere.
    /// Each check is one linear pass.
    static func checkProlog(_ text: String) throws {
        let lower = text.lowercased()
        if lower.contains("<!doctype") || lower.contains("<!entity") { throw ConversionError.watermarkSVGUnsafe }
        guard lower.hasPrefix("<?xml"), let end = lower.range(of: "?>") else { return }
        let declaration = lower[..<end.lowerBound]
        guard let key = declaration.range(of: "encoding") else { return }
        let value = declaration[key.upperBound...].drop { $0.isWhitespace || $0 == "=" || $0 == "\"" || $0 == "'" }
            .prefix { $0 != "\"" && $0 != "'" && !$0.isWhitespace }
        guard value == "utf-8" || value == "utf8" else { throw ConversionError.watermarkSVGUnsafe }
    }

    static func parse(_ data: Data) throws -> Element {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        let builder = TreeBuilder()
        parser.delegate = builder
        let parsed = parser.parse()
        if let refusal = builder.refusal { throw refusal }
        guard parsed, let root = builder.root else { throw ConversionError.watermarkImageUnreadable }
        return root
    }

    // MARK: Validation

    /// The canonical name for an allowed attribute, or a throw. `uri` is the attribute's namespace (nil: none).
    static func validatedAttribute(element: String, name: String, uri: String?, value: String) throws -> String {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch uri {
        case nil:
            if local == "href" { return try link(element: element, value: value) }
            guard attributes.contains(local) || attributePrefixes.contains(where: local.hasPrefix) else {
                throw ConversionError.watermarkSVGUnsafe
            }
        case xlinkNamespace?:
            guard local == "href" else { throw ConversionError.watermarkSVGUnsafe }
            return try link(element: element, value: value)
        case xmlNamespace? where local == "space":
            return "xml:space"
        default:
            throw ConversionError.watermarkSVGUnsafe
        }
        try checkValue(value, isStyle: local == "style")
        return local
    }

    private static func link(element: String, value: String) throws -> String {
        guard linkElements.contains(element), isLocalReference(value) else { throw ConversionError.watermarkSVGUnsafe }
        return "xlink:href"
    }

    /// `#` followed by an XML-name-like id.
    static func isLocalReference(_ value: String) -> Bool {
        guard value.first == "#" else { return false }
        let id = value.dropFirst()
        guard let first = id.first, first.isLetter || first == "_" else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// Every `url(` must be exactly `url(#id)`; a style value may not use `@`, `\`, `expression` or `import`.
    static func checkValue(_ value: String, isStyle: Bool) throws {
        let lower = value.lowercased()
        if isStyle, ["@", "\\", "expression", "import"].contains(where: lower.contains) {
            throw ConversionError.watermarkSVGUnsafe
        }
        var rest = Substring(lower)
        while let open = rest.range(of: "url(") {
            guard let close = rest[open.upperBound...].firstIndex(of: ")"),
                  isLocalReference(String(rest[open.upperBound..<close])) else {
                throw ConversionError.watermarkSVGUnsafe
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

    // MARK: Parsing

    /// Builds the validated tree while parsing; the first violation aborts the parse.
    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Element?
        var refusal: ConversionError?
        private var stack: [Element] = []
        private var prefixes: [String: [String]] = [:]
        private var count = 0

        private func refuse(_ parser: XMLParser, _ error: ConversionError = .watermarkSVGUnsafe) {
            if refusal == nil { refusal = error }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixes[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            _ = prefixes[prefix]?.popLast()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard refusal == nil else { return }
            count += 1
            guard count <= maxElements, stack.count < maxDepth else { return refuse(parser) }
            // The root decides whether this is an SVG at all; anything else inside it is a violation.
            guard namespaceURI == svgNamespace, elements.contains(elementName) else {
                return refuse(parser, stack.isEmpty ? .watermarkImageUnreadable : .watermarkSVGUnsafe)
            }
            if stack.isEmpty, elementName != "svg" { return refuse(parser, .watermarkImageUnreadable) }
            let element = Element(name: elementName)
            // Sorted, so the canonical output doesn't depend on dictionary order.
            for (name, value) in attributeDict.sorted(by: { $0.key < $1.key }) {
                let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
                let uri: String? = parts.count == 2
                    ? (parts[0] == "xml" ? xmlNamespace : prefixes[parts[0]]?.last ?? "unbound:") : nil
                do {
                    let canonical = try validatedAttribute(element: elementName, name: name, uri: uri, value: value)
                    // `href` and `xlink:href` both become `xlink:href`; keep one.
                    if !element.attributes.contains(where: { $0.0 == canonical }) {
                        element.attributes.append((canonical, value))
                    }
                } catch {
                    return refuse(parser, error as? ConversionError ?? .watermarkSVGUnsafe)
                }
            }
            if let parent = stack.last { parent.children.append(.element(element)) } else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let current = stack.last, textElements.contains(current.name) else { return }
            current.children.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let current = stack.last, textElements.contains(current.name),
                  let string = String(data: CDATABlock, encoding: .utf8) else { return }
            current.children.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            refuse(parser)
        }

        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
            refuse(parser)
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            refuse(parser)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
                    systemID: String?) {
            refuse(parser)
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            refuse(parser)
            return nil
        }
    }
}
