import Foundation

/// What happens to characters outside letters, digits, `-`, `_` and `.` in a name.
public enum SpecialCharacters: String, Codable, CaseIterable, Sendable {
    case keep, replace, remove
}

/// How the words of a name are cased and joined.
public enum CaseStyle: String, Codable, CaseIterable, Sendable {
    case keep, lower, upper, camel, pascal, snake, kebab, title
}

/// Pure text transforms for rename options. They work on Characters, so letters with
/// diacritics stay letters and are never split.
public enum NameTransforms {
    /// The replacement characters that are allowed; anything else decodes as `-`.
    public static let allowedReplacements: Set<String> = ["-", "_", ".", ""]

    public static func removeSpaces(_ name: String) -> String {
        String(name.filter { !$0.isWhitespace })
    }

    private static func isKept(_ char: Character) -> Bool {
        char.isLetter || char.unicodeScalars.allSatisfy { $0.properties.numericType == .decimal }
            || char == "-" || char == "_" || char == "."
    }

    /// Note that `replace` also collapses and trims runs of the replacement character already in the name.
    /// `replace` swaps each run of other characters for `replacement` (runs of the replacement collapse to one,
    /// and it is trimmed from both ends); `remove` drops them.
    public static func specialCharacters(_ name: String, mode: SpecialCharacters, replacement: String) -> String {
        switch mode {
        case .keep: return name
        case .remove: return String(name.filter(isKept))
        case .replace: return replaceRuns(name, with: allowedReplacements.contains(replacement) ? replacement : "-")
        }
    }

    private static func replaceRuns(_ name: String, with sub: String) -> String {
        var out = ""
        var pendingRun = false
        for char in name {
            if isKept(char) {
                if pendingRun { out += sub }
                pendingRun = false
                out.append(char)
            } else {
                pendingRun = true
            }
        }
        if pendingRun { out += sub }
        guard let mark = sub.first else { return out }
        var chars = Substring(out)
        while chars.first == mark { chars = chars.dropFirst() }
        while chars.last == mark { chars = chars.dropLast() }
        var result = ""
        for char in chars where !(char == mark && result.last == mark) { result.append(char) }
        return result
    }

    /// Words split on spaces, `-`, `_`, `.` and lower-to-upper boundaries; digits stay attached to their word.
    static func words(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for char in name {
            if char.isWhitespace || char == "-" || char == "_" || char == "." {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if let previous, previous.isLowercase, char.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(char)
            }
            previous = char
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func capitalised(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst().lowercased()
    }

    public static func caseStyle(_ name: String, style: CaseStyle) -> String {
        switch style {
        case .keep: return name
        case .lower: return name.lowercased()
        case .upper: return name.uppercased()
        case .snake: return words(name).map { $0.lowercased() }.joined(separator: "_")
        case .kebab: return words(name).map { $0.lowercased() }.joined(separator: "-")
        case .pascal: return words(name).map(capitalised).joined()
        case .camel:
            let all = words(name)
            guard let first = all.first else { return "" }
            return first.lowercased() + all.dropFirst().map(capitalised).joined()
        case .title:
            // Splits on spaces, `_` and `-` but keeps them, so only each word's first letter changes.
            var out = ""
            var atStart = true
            for char in name {
                out += atStart ? String(char).uppercased() : String(char).lowercased()
                atStart = char.isWhitespace || char == "_" || char == "-"
            }
            return out
        }
    }
}

extension RenameOptions {
    /// The raw-name pipeline: find/replace, prefix and suffix, spaces, special characters, case style.
    /// Sanitising and the fallback name follow in `RenameTemplate.render`.
    func transformName(_ rendered: String) -> String {
        var name = replacing(in: rendered)
        name = prefix + name + suffix
        if removeSpaces { name = NameTransforms.removeSpaces(name) }
        name = NameTransforms.specialCharacters(name, mode: specialCharacters, replacement: replacement)
        return NameTransforms.caseStyle(name, style: caseStyle)
    }

    /// The one place a base name is made: used by the batch, the preview and the live example.
    func render(_ template: RenameTemplate, _ context: RenameContext) -> String {
        template.render(context, transform: transformName)
    }
}
