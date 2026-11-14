import Foundation

/// Checks that need the whole tree: `style` declarations, and the reference graph (CoreSVG crashes on some
/// indirect `use` cycles and expands `use` fan-out exponentially, so both are refused before it sees them).
extension SVGSanitizer {
    /// Allowed property names in `style`, lowercased (CSS names are case-insensitive).
    private static let styleProperties = Set(attributes.map { $0.lowercased() })

    /// Each `prop: value` declaration must name an allowed property, and the only functions allowed in a value
    /// are `url(#id)` (checked by the caller) and the colour functions. `lower` is the lowercased style value.
    static func checkStyle(_ lower: String) throws {
        for declaration in lower.split(separator: ";") {
            let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { throw ConversionError.watermarkSVGUnsafe }
            let property = parts[0].trimmingCharacters(in: .whitespaces)
            guard styleProperties.contains(property) || attributePrefixes.contains(where: property.hasPrefix),
                  property != "style" else { throw ConversionError.watermarkSVGUnsafe }
            try checkFunctions(parts[1])
        }
    }

    /// Colour functions allowed in style values, with plain numeric arguments only.
    static let colourFunctions: Set<String> = ["rgb", "rgba", "hsl", "hsla"]

    /// Every `(` must follow the function name `url`, or a colour function whose arguments are only digits,
    /// `%`, commas, spaces and dots. `value` is lowercased.
    static func checkFunctions(_ value: Substring) throws {
        var index = value.startIndex
        while let open = value[index...].firstIndex(of: "(") {
            let before = value[..<open]
            let name = String(before.reversed().drop { $0.isWhitespace }
                .prefix { $0.isLetter || $0.isNumber || $0 == "-" }.reversed())
            index = value.index(after: open)
            if name == "url" { continue }
            guard colourFunctions.contains(name), let close = value[index...].firstIndex(of: ")"),
                  value[index..<close].allSatisfy({ $0.isASCII && ($0.isNumber || "%,. ".contains($0)) }) else {
                throw ConversionError.watermarkSVGUnsafe
            }
            index = value.index(after: close)
        }
    }

    // MARK: Reference graph

    /// Elements whose content is drawn again wherever they are referenced.
    private static let instantiated: Set<String> = ["pattern", "mask", "clipPath"]

    /// Refuses a reference cycle (through `href` or any `url(#id)`, together with nesting) and a file whose
    /// expanded instance count (each `use`, pattern, mask or clip path drawing its target's subtree again)
    /// exceeds `maxInstances`. Iterative, so a long chain can't exhaust the stack.
    static func checkReferences(_ root: Element) throws {
        var nodes: [Element] = []
        var index: [ObjectIdentifier: Int] = [:]
        var pending = [root]
        while let element = pending.popLast() {
            index[ObjectIdentifier(element)] = nodes.count
            nodes.append(element)
            for case .element(let child) in element.children { pending.append(child) }
        }
        var ids: [String: Int] = [:]
        for (position, element) in nodes.enumerated() {
            guard let id = element.attributes.first(where: { $0.0 == "id" })?.1 else { continue }
            // Duplicate ids make the target depend on the renderer; refuse them.
            guard ids.updateValue(position, forKey: id) == nil else { throw ConversionError.watermarkSVGUnsafe }
        }
        // Edges: children (part of the subtree) and references (counted only when they draw the target again).
        let edges: [[(target: Int, counts: Bool)]] = nodes.map { element in
            var list = element.children.compactMap { child -> (Int, Bool)? in
                if case .element(let nested) = child { return index[ObjectIdentifier(nested)].map { ($0, true) } }
                return nil
            }
            for (name, value) in element.attributes {
                for id in referencedIDs(name: name, value: value) {
                    guard let target = ids[id] else { continue }
                    let counts = name == "xlink:href" ? element.name == "use" : instantiated.contains(nodes[target].name)
                    list.append((target, counts))
                }
            }
            return list
        }
        try walk(edges, from: index[ObjectIdentifier(root)] ?? 0)
    }

    /// Post-order DFS: grey/black colouring finds cycles, and each node's weight is 1 plus the weights of its
    /// counted edges, saturating just above the cap.
    private static func walk(_ edges: [[(target: Int, counts: Bool)]], from root: Int) throws {
        enum State { case new, open, done }
        var state = [State](repeating: .new, count: edges.count)
        var weight = [Int](repeating: 0, count: edges.count)
        var stack: [(node: Int, next: Int)] = [(root, 0)]
        state[root] = .open
        while let (node, next) = stack.last {
            if next < edges[node].count {
                stack[stack.count - 1].next += 1
                let target = edges[node][next].target
                switch state[target] {
                case .open: throw ConversionError.watermarkSVGUnsafe
                case .new:
                    state[target] = .open
                    stack.append((target, 0))
                case .done: break
                }
                continue
            }
            var total = 1
            for edge in edges[node] where edge.counts {
                total = min(maxInstances + 1, total + weight[edge.target])
            }
            guard total <= maxInstances else { throw ConversionError.watermarkSVGUnsafe }
            weight[node] = total
            state[node] = .done
            stack.removeLast()
        }
    }

    /// The ids an attribute points to: `xlink:href="#id"` and every `url(#id)`.
    static func referencedIDs(name: String, value: String) -> [String] {
        if name == "xlink:href" { return [String(value.dropFirst())] }
        var ids: [String] = []
        var rest = Substring(value)
        while let open = rest.range(of: #"url\s*\("#, options: [.regularExpression, .caseInsensitive]) {
            guard let close = rest[open.upperBound...].firstIndex(of: ")") else { break }
            let reference = rest[open.upperBound..<close].trimmingCharacters(in: .whitespaces)
            if reference.hasPrefix("#") { ids.append(String(reference.dropFirst())) }
            rest = rest[rest.index(after: close)...]
        }
        return ids
    }
}
