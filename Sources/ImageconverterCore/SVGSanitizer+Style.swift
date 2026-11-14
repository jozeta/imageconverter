import Foundation

/// Simple `<style>` sheets as design tools export them (`.st0{fill:#E30613;}`), inlined as presentation
/// attributes. Only `.class`, `#id` and element-name selectors (in comma lists) and presentation properties are
/// accepted; anything else in the CSS refuses the file. Every inlined declaration goes through
/// `validatedAttribute` like any attribute in the file, and the reference checks run after inlining.
extension SVGSanitizer {
    /// Properties a style sheet may set: the allowlist's presentation attributes (plus the `stroke-`, `fill-`
    /// and `font-` families). Geometry and structure (`d`, `x`, `transform`, `href`, ...) can't come from CSS.
    static let presentationProperties: Set<String> = [
        "fill", "stroke", "opacity", "text-anchor", "dominant-baseline", "alignment-baseline", "baseline-shift",
        "stop-color", "stop-opacity", "clip-path", "clip-rule", "mask", "display", "visibility", "color",
        "letter-spacing", "word-spacing", "vector-effect", "shape-rendering", "paint-order", "enable-background",
    ]
    /// Most classes on one element.
    static let maxClasses = 16
    /// Most bytes of values inlined over the whole file, so a short rule matching many elements can't blow up.
    static let maxInlinedBytes = 2 * SVGRasterizer.maxFileSize

    enum Selector: Hashable {
        case className(String)
        case id(String)
        case element(String)
    }

    /// Per selector, its declarations: property → (position in the sheet, value). Later positions win.
    typealias StyleSheet = [Selector: [String: (order: Int, value: String)]]

    /// The tokens of a `class` value, or nil when there are too many or one isn't a plain identifier.
    static func classTokens(_ value: String) -> [String]? {
        let tokens = value.split(whereSeparator: { " \t\n\r".contains($0) }).map(String.init)
        guard tokens.count <= maxClasses, tokens.allSatisfy(isIdentifier) else { return nil }
        return tokens
    }

    /// ASCII letters, digits, `-` and `_`, not starting with a digit.
    static func isIdentifier(_ text: some StringProtocol) -> Bool {
        guard let first = text.first, !first.isNumber else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func isPresentationProperty(_ name: String) -> Bool {
        isIdentifier(name) && (presentationProperties.contains(name) || attributePrefixes.contains(where: name.hasPrefix))
    }

    // MARK: Inlining

    /// Applies `styles` (the text of every `<style>`, in document order) to the tree: on each element, the
    /// declarations of the rules matching its name, classes or id (later rules win) become attributes, except
    /// where the element already has that attribute.
    static func inlineStyles(_ styles: [String], into root: Element) throws {
        guard !styles.isEmpty else { return }
        let sheet = try parseStyleSheet(styles.joined(separator: "\n"))
        guard !sheet.isEmpty else { return }
        var budget = maxInlinedBytes
        var pending = [root]
        while let element = pending.popLast() {
            for case .element(let child) in element.children { pending.append(child) }
            var keys = [Selector.element(element.name)] + element.classes.map(Selector.className)
            if let id = element.attributes.first(where: { $0.0 == "id" })?.1 { keys.append(.id(id)) }
            var chosen: [String: (order: Int, value: String)] = [:]
            for key in keys {
                for (property, entry) in sheet[key] ?? [:] where (chosen[property]?.order ?? -1) < entry.order {
                    chosen[property] = entry
                }
            }
            let present = Set(element.attributes.map(\.0))
            // Sorted, so the canonical output doesn't depend on dictionary order.
            for (property, entry) in chosen.sorted(by: { $0.key < $1.key }) where !present.contains(property) {
                budget -= entry.value.utf8.count
                guard budget >= 0 else { throw ConversionError.watermarkSVGUnsafe }
                let name = try validatedAttribute(element: element.name, name: property, uri: nil, value: entry.value)
                element.attributes.append((name, entry.value))
            }
            guard element.attributes.count <= maxAttributes else { throw ConversionError.watermarkSVGUnsafe }
        }
    }

    // MARK: Parsing

    /// The rules of `css`, or a refusal for anything outside the simple subset: at-rules (`@import` counts as a
    /// link to another file), escapes, `!important`, combinators, pseudo-classes, attribute selectors, nesting.
    static func parseStyleSheet(_ css: String) throws -> StyleSheet {
        let text = try strippingComments(css)
        let lower = text.lowercased()
        if lower.contains("@import") { throw ConversionError.watermarkSVGExternal }
        if ["@", "\\", "!", "<", "expression"].contains(where: lower.contains) { throw ConversionError.watermarkSVGUnsafe }
        var sheet: StyleSheet = [:]
        var order = 0
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { throw ConversionError.watermarkSVGUnsafe }
            let selectorText = rest[..<open]
            let body = rest[rest.index(after: open)..<close]
            guard !selectorText.contains("}") else { throw ConversionError.watermarkSVGUnsafe }
            let selectors = try selectorText.split(separator: ",", omittingEmptySubsequences: false).map(selector)
            for (property, value) in try declarations(body) {
                order += 1
                for key in selectors { sheet[key, default: [:]][property] = (order, value) }
            }
            rest = rest[rest.index(after: close)...]
        }
        guard rest.allSatisfy(\.isWhitespace) else { throw ConversionError.watermarkSVGUnsafe }
        return sheet
    }

    /// `/* ... */` comments replaced by a space; an unterminated one refuses.
    private static func strippingComments(_ css: String) throws -> String {
        var out = ""
        var rest = Substring(css)
        while let open = rest.range(of: "/*") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "*/") else { throw ConversionError.watermarkSVGUnsafe }
            out += " "
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private static func selector(_ raw: Substring) throws -> Selector {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("."), isIdentifier(text.dropFirst()) { return .className(String(text.dropFirst())) }
        if text.hasPrefix("#"), isIdentifier(text.dropFirst()) { return .id(String(text.dropFirst())) }
        if isIdentifier(text) { return .element(text) }
        throw ConversionError.watermarkSVGUnsafe
    }

    /// A rule body's `property: value` pairs (a repeated property keeps its last value). Each is checked like an
    /// attribute here too, so a rule that matches nothing can't hide anything either.
    private static func declarations(_ body: Substring) throws -> [(String, String)] {
        var result: [(String, String)] = []
        var positions: [String: Int] = [:]
        for declaration in body.split(separator: ";") {
            let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { throw ConversionError.watermarkSVGUnsafe }
            let property = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPresentationProperty(property), !value.isEmpty else { throw ConversionError.watermarkSVGUnsafe }
            try checkFunctions(Substring(value.lowercased()))
            _ = try validatedAttribute(element: "g", name: property, uri: nil, value: value)
            if let position = positions[property] {
                result[position].1 = value
            } else {
                positions[property] = result.count
                result.append((property, value))
            }
        }
        guard result.count <= maxAttributes else { throw ConversionError.watermarkSVGUnsafe }
        return result
    }
}
