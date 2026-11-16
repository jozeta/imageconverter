import Foundation

/// The condition step's wording: words only, never operator symbols.
extension ConditionalStep {
    /// One-line description for the pipeline list: `if longest edge is more than 2048 px → resize · else → skip`.
    public var summary: String {
        let joiner = match == .all ? " and " : " or "
        var text = "if " + conditions.map(\.summary).joined(separator: joiner) + " → " + Self.summary(of: then)
        if !otherwise.isEmpty { text += " · else → " + Self.summary(of: otherwise) }
        return text
    }

    private static func summary(of actions: [ConditionalAction]) -> String {
        guard !actions.isEmpty else { return "nothing" }
        return actions.map(\.summary).joined(separator: ", ")
    }
}

extension ConditionalAction {
    /// `resize`, `save as PNG`, `save into “Portraits”`, `apply preset “Web”`.
    public var summary: String {
        switch self {
        case .step(let step): return step.operation.kind.displayName.lowercased()
        case .output(let settings): return "save as \(settings.format.displayName)"
        case .metadata: return "metadata"
        case .rename: return "rename"
        case .copyOriginal: return "copy unchanged"
        case .skip: return "skip"
        case .subfolder(let template): return "save into “\(template)”"
        case .finderTags(let tags): return "tag " + FinderTags.normalized(tags).joined(separator: ", ")
        case .preset(let link): return "apply preset “\(link.name)”"
        case .addKeywords(let keywords):
            return "add keywords " + MetadataFields.normalizedKeywords(keywords).joined(separator: ", ")
        case .stop: return "stop checking conditions"
        case .skipExtraOutputs: return "skip extra outputs"
        case .note(let text): return "note “\(text.count > 30 ? String(text.prefix(30)) + "…" : text)”"
        }
    }
}

extension Condition {
    /// `longest edge is more than 2048 px`, `name does not start with “IMG”`, `has no date taken`.
    public var summary: String { check.summary(negated: negated) }
}

extension ConditionCheck {
    // One case per check keeps every wording in one place.
    // swiftlint:disable cyclomatic_complexity
    /// The check in words, in its negative form when `negated`.
    public func summary(negated: Bool = false) -> String {
        let isPhrase = negated ? "is not" : "is"
        switch self {
        case .longestEdge(let comparison, let value): return "longest edge \(Self.phrase(comparison, negated)) \(value) px"
        case .width(let comparison, let value): return "width \(Self.phrase(comparison, negated)) \(value) px"
        case .height(let comparison, let value): return "height \(Self.phrase(comparison, negated)) \(value) px"
        case .fileSize(let comparison, let bytes):
            return "file size \(Self.phrase(comparison, negated)) \(SizeFormat.bytes(bytes))"
        case .format(.format(let format)): return "format \(isPhrase) \(format.displayName)"
        case .format(.type(let identifier)): return "type \(isPhrase) \(identifier)"
        case .hasTransparency(let wanted): return wanted != negated ? "has transparency" : "has no transparency"
        case .orientation(let orientation): return "\(isPhrase) \(orientation.rawValue)"
        case .hasGPS(let wanted): return wanted != negated ? "has location" : "has no location"
        case .camera(let text): return "camera \(negated ? "does not contain" : "contains") “\(text)”"
        case .name(let match):
            let operation = negated ? match.operation.negatedPhrase : match.operation.phrase
            return "name \(operation) “\(match.text)”" + (match.ignoresCase ? "" : ", matching case")
        case .fileExtension(let list): return "extension \(isPhrase) " + Self.list(list, joiner: "or")
        case .folder(let text): return "folder \(negated ? "does not contain" : "contains") “\(text)”"
        case .date(let field, let rule): return Self.summary(field, rule, negated: negated)
        case .metadata(let test): return Self.summary(test, negated: negated)
        default: return imageSummary(negated: negated)
        }
    }
    // swiftlint:enable cyclomatic_complexity

    // One case per check.
    // swiftlint:disable:next cyclomatic_complexity
    private func imageSummary(negated: Bool) -> String {
        let isPhrase = negated ? "is not" : "is"
        switch self {
        case .megapixels(let comparison, let value):
            return "size \(Self.phrase(comparison, negated)) \(Self.number(value)) megapixels"
        case .aspectRatio(.widerThan(let ratio)): return "\(isPhrase) wider than \(Self.number(ratio)) to 1"
        case .aspectRatio(.tallerThan(let ratio)): return "\(isPhrase) taller than \(Self.number(ratio)) to 1"
        case .aspectRatio(.square): return "\(isPhrase) about square"
        case .bitDepth(let depth): return "\(isPhrase) \(depth.displayName)"
        case .colorSpace(let kind): return "color space \(isPhrase) \(kind.displayName)"
        case .hasProfile: return negated ? "has no color profile" : "has a color profile"
        case .dpi(let comparison, let value): return "DPI \(Self.phrase(comparison, negated)) \(value)"
        case .isRotated: return "\(isPhrase) rotated by its EXIF orientation"
        case .isAnimated: return negated ? "is a single image" : "is animated or has several pages"
        default: return contentSummary(negated: negated)
        }
    }

    private static func summary(_ field: DateField, _ rule: DateRule, negated: Bool) -> String {
        let isPhrase = negated ? "is not" : "is"
        let name = field.displayName
        switch rule {
        case .exists:
            let what = field == .taken ? "date taken" : "\(name) date"
            return negated ? "has no \(what)" : "has a \(what)"
        case .before(let day): return "\(name) \(isPhrase) before \(day.text)"
        case .after(let day): return "\(name) \(isPhrase) after \(day.text)"
        case .between(let from, let until): return "\(name) \(isPhrase) between \(from.text) and \(until.text)"
        case .withinLastDays(let days):
            return "\(name) \(isPhrase) within the last \(days == 1 ? "day" : "\(days) days")"
        case .inYear(let year): return "\(name) \(isPhrase) in \(year)"
        case .inMonth(let month): return "\(name) \(isPhrase) in \(monthName(month))"
        }
    }

    private static func summary(_ test: MetadataTest, negated: Bool) -> String {
        let operation = negated ? test.operation.negatedPhrase : test.operation.phrase
        var text = "\(test.subject.displayName) \(operation)"
        guard test.operation.takesValue else { return text }
        let value = test.value.trimmingCharacters(in: .whitespaces)
        if test.subject.isNumeric, case .named(let field) = test.subject {
            text += " " + value + (field.unit.isEmpty ? "" : " \(field.unit)")
        } else {
            text += " “\(value)”"
        }
        return text
    }

    /// `January` … `December`.
    public static func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let names = formatter.standaloneMonthSymbols ?? []
        return names.indices.contains(month - 1) ? names[month - 1] : "month \(month)"
    }

    private static func phrase(_ comparison: Comparison, _ negated: Bool) -> String {
        negated ? comparison.negatedPhrase : comparison.phrase
    }

    /// `jpg`, `jpg or png`, `jpg, png or heic`.
    private static func list(_ items: [String], joiner: String) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(joiner) " + last
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...2))
            .grouping(.never))
    }
}
