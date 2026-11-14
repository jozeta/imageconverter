import Foundation

extension SVGSanitizer {
    /// Builds the validated tree while parsing; the first violation aborts the parse.
    final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Element?
        var refusal: ConversionError?
        /// The character data of each `<style>` element (they are not part of the tree).
        var styles: [String] = []
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
            guard count <= maxElements, stack.count < maxDepth, attributeDict.count <= maxAttributes,
                  stack.last?.name != "style" else {
                return refuse(parser)
            }
            if !stack.isEmpty, namespaceURI == svgNamespace, elementName == "style" {
                return startStyle(parser, attributes: attributeDict)
            }
            // The root decides whether this is an SVG at all; anything else inside it is a violation.
            guard namespaceURI == svgNamespace, elements.contains(elementName) else {
                let external = namespaceURI == svgNamespace && externalElements.contains(elementName)
                return refuse(parser, stack.isEmpty ? .watermarkSVGInvalid : external ? .watermarkSVGExternal
                    : .watermarkSVGUnsafe)
            }
            if stack.isEmpty, elementName != "svg" { return refuse(parser, .watermarkSVGInvalid) }
            let element = Element(name: elementName)
            do {
                try addAttributes(attributeDict, to: element)
            } catch {
                return refuse(parser, error as? ConversionError ?? .watermarkSVGUnsafe)
            }
            if let parent = stack.last { parent.children.append(.element(element)) } else { root = element }
            stack.append(element)
        }

        private func addAttributes(_ attributeDict: [String: String], to element: Element) throws {
            var seen = Set<String>()
            // Sorted, so the canonical output doesn't depend on dictionary order.
            for (name, value) in attributeDict.sorted(by: { $0.key < $1.key }) {
                if name == "class" {
                    guard let tokens = classTokens(value) else { throw ConversionError.watermarkSVGUnsafe }
                    element.classes = tokens
                    continue
                }
                let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
                let uri: String? = parts.count == 2
                    ? (parts[0] == "xml" ? xmlNamespace : prefixes[parts[0]]?.last ?? "unbound:") : nil
                let normalized = normalizedURLs(value)
                let canonical = try validatedAttribute(element: element.name, name: name, uri: uri, value: normalized)
                // `href` and `xlink:href` both become `xlink:href`; keep one.
                if seen.insert(canonical).inserted { element.attributes.append((canonical, normalized)) }
            }
        }

        /// A `<style>` with at most `type="text/css"`; kept out of the tree, its text collected for inlining.
        private func startStyle(_ parser: XMLParser, attributes attributeDict: [String: String]) {
            for (name, value) in attributeDict {
                guard name == "type", value.trimmingCharacters(in: .whitespaces).lowercased() == "text/css" else {
                    return refuse(parser)
                }
            }
            styles.append("")
            stack.append(Element(name: "style"))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
            append(string)
        }

        private func append(_ string: String) {
            guard let current = stack.last else { return }
            if current.name == "style", !styles.isEmpty {
                styles[styles.count - 1] += string
            } else if textElements.contains(current.name) {
                current.children.append(.text(string))
            }
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            refuse(parser, target.lowercased() == "xml-stylesheet" ? .watermarkSVGExternal : .watermarkSVGUnsafe)
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
