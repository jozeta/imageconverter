import Foundation

/// A "Shows" test: Vision's classifier sees any (or all) of `labels` with at least `minimumConfidence`.
/// Labels are classifier identifiers (`dog`, `musical_instrument`), never display text.
public struct LabelMatch: Codable, Equatable, Sendable {
    public var labels: [String]
    public var requiresAll: Bool
    public var minimumConfidence: Double

    public init(_ labels: [String], requiresAll: Bool = false,
                minimumConfidence: Double = ImageAnalysis.defaultConfidence) {
        self.labels = labels
        self.requiresAll = requiresAll
        self.minimumConfidence = minimumConfidence
    }

    public static let maxLabels = 20
    /// The confidence a test can ask for.
    public static let confidenceRange = ImageAnalysis.labelFloor...1.0

    private enum CodingKeys: String, CodingKey { case labels, requiresAll, minimumConfidence }

    /// Lenient: a missing match mode is "any", a missing confidence the default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labels = try container.decode([String].self, forKey: .labels)
        requiresAll = (try? container.decodeIfPresent(Bool.self, forKey: .requiresAll)) ?? false
        minimumConfidence = (try? container.decodeIfPresent(Double.self, forKey: .minimumConfidence))
            ?? ImageAnalysis.defaultConfidence
    }

    /// 1...20 valid identifiers and a confidence in 0.05...1.
    public var isValid: Bool {
        !labels.isEmpty && labels.count <= Self.maxLabels && labels.allSatisfy(ImageLabel.isValidIdentifier)
            && minimumConfidence.isFinite && Self.confidenceRange.contains(minimumConfidence)
    }

    public func matches(_ found: [ImageLabel]) -> Bool {
        let seen = Set(found.filter { $0.confidence >= minimumConfidence }.map(\.identifier))
        guard !labels.isEmpty else { return false }
        return requiresAll ? labels.allSatisfy(seen.contains) : labels.contains(where: seen.contains)
    }
}

extension ConditionCheck {
    public static let maxFaceCount = 1000

    /// True when the check reads the on-device image analysis.
    public var isContentCheck: Bool { !needs.isDisjoint(with: .analysis) }

    /// True for the checks that need macOS 15 (the aesthetics request).
    public var needsMacOS15: Bool { needs.contains(.aesthetics) }

    var isValidContent: Bool {
        switch self {
        case .shows(let match): return match.isValid
        case .faceCount(_, let count): return (0...Self.maxFaceCount).contains(count)
        case .aesthetics(_, let score): return score.isFinite && (-1...1).contains(score)
        case .containsText, .isUtility: return true
        default: return false
        }
    }

    /// False when the analysis has no value for this check (not asked for, failed, or needs a newer system).
    func hasContentValue(in analysis: ImageAnalysis) -> Bool {
        switch self {
        case .shows: return analysis.labels != nil
        case .faceCount: return analysis.faceCount != nil
        case .containsText: return analysis.hasText != nil
        case .aesthetics: return analysis.aestheticsScore != nil
        case .isUtility: return analysis.isUtility != nil
        default: return true
        }
    }

    func matchesContent(_ analysis: ImageAnalysis) -> Bool {
        switch self {
        case .shows(let match): return match.matches(analysis.labels ?? [])
        case .faceCount(let comparison, let count): return analysis.faceCount.map { comparison.test($0, count) } ?? false
        case .containsText(let wanted): return analysis.hasText == wanted
        case .aesthetics(let comparison, let score):
            return analysis.aestheticsScore.map { comparison.test($0, score) } ?? false
        case .isUtility: return analysis.isUtility == true
        default: return false
        }
    }

    /// `shows dog or cat`, `has 2 or more faces`, `contains text`, `aesthetics score is at least 0.2`,
    /// `is a screenshot or document`.
    func contentSummary(negated: Bool) -> String {
        switch self {
        case .shows(let match):
            let names = match.labels.map(ImageLabel.displayName)
            let joiner = match.requiresAll ? "and" : "or"
            var text = (negated ? "does not show " : "shows ") + Self.joinedList(names, joiner: joiner)
            if match.minimumConfidence != ImageAnalysis.defaultConfidence {
                text += " (confidence at least \(Self.decimal(match.minimumConfidence)))"
            }
            return text
        case .faceCount(let comparison, let count):
            return (negated ? "does not have " : "has ") + Self.faces(comparison, count)
        case .containsText(let wanted): return wanted != negated ? "contains text" : "contains no text"
        case .aesthetics(let comparison, let score):
            return "aesthetics score \(negated ? comparison.negatedPhrase : comparison.phrase) \(Self.decimal(score))"
        case .isUtility: return negated ? "is not a screenshot or document" : "is a screenshot or document"
        default: return ""
        }
    }

    /// `2 or more faces`, `more than 1 face`, `fewer than 3 faces`, `2 or fewer faces`.
    private static func faces(_ comparison: Comparison, _ count: Int) -> String {
        let noun = count == 1 ? "face" : "faces"
        switch comparison {
        case .atLeast: return "\(count) or more faces"
        case .greaterThan: return "more than \(count) \(noun)"
        case .lessThan: return "fewer than \(count) \(noun)"
        case .atMost: return "\(count) or fewer faces"
        }
    }

    /// `dog`, `dog or cat`, `dog, cat or bird`.
    static func joinedList(_ items: [String], joiner: String) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(joiner) " + last
    }

    static func decimal(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...2))
            .grouping(.never))
    }
}

/// The `{labels}` token in keyword and Finder tag lists: an entry with it becomes one entry per label.
public enum LabelToken {
    public static let token = "{labels}"

    /// True when any of `values` uses `{labels}`.
    public static func isUsed(in values: [String]) -> Bool {
        values.contains { $0.contains(token) }
    }

    /// Each entry with `{labels}` repeated for every label, the token replaced by it (`ai-{labels}` → `ai-dog`,
    /// `ai-grass`); dropped when there are no labels. Other entries stay as they are. The caller's sanitiser
    /// (`FinderTags.normalized`, `MetadataFields.normalizedKeywords`) cleans and limits the result.
    public static func expand(_ values: [String], labels: [String]) -> [String] {
        values.flatMap { value -> [String] in
            guard value.contains(token) else { return [value] }
            return labels.map { value.replacingOccurrences(of: token, with: $0) }
        }
    }
}

extension ConditionalAction {
    /// True when the action's text uses `{labels}` (so the files' labels must be found).
    var usesLabels: Bool {
        switch self {
        case .subfolder(let template), .note(let template): return template.contains(LabelToken.token)
        case .finderTags(let values), .addKeywords(let values): return LabelToken.isUsed(in: values)
        default: return false
        }
    }
}
