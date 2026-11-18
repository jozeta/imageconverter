import Foundation
import UniformTypeIdentifiers

/// How a condition compares a number with its limit.
public enum Comparison: String, Codable, CaseIterable, Sendable {
    case greaterThan, lessThan, atLeast, atMost

    public func test<Value: Comparable>(_ value: Value, _ limit: Value) -> Bool {
        switch self {
        case .greaterThan: return value > limit
        case .lessThan: return value < limit
        case .atLeast: return value >= limit
        case .atMost: return value <= limit
        }
    }

    /// The comparison in words, as shown in the editor and the step summary ("is more than").
    public var phrase: String {
        switch self {
        case .greaterThan: return "is more than"
        case .lessThan: return "is less than"
        case .atLeast: return "is at least"
        case .atMost: return "is at most"
        }
    }

    /// The negative form ("is not more than").
    public var negatedPhrase: String { phrase.replacingOccurrences(of: "is ", with: "is not ") }
}

/// The shape of an upright image.
public enum Orientation: String, Codable, CaseIterable, Sendable {
    case portrait, landscape, square

    public init(width: Int, height: Int) {
        self = width == height ? .square : (height > width ? .portrait : .landscape)
    }
}

/// What a format condition matches: a writable format, or any source type identifier (and the types that
/// conform to it, e.g. `public.camera-raw-image` for every RAW format).
public enum FormatMatch: Codable, Equatable, Sendable {
    case format(OutputFormat)
    case type(String)
}

/// One test against a source file's facts, optionally negated ("is not", "does not contain"). Saved as its check
/// alone (as before negation existed), or as `{"not": check}` when negated.
public struct Condition: Codable, Equatable, Sendable {
    public var check: ConditionCheck
    public var negated: Bool

    public init(_ check: ConditionCheck, negated: Bool = false) {
        self.check = check
        self.negated = negated
    }

    /// Limits for hand-edited presets: sizes in pixels and bytes, and text lengths.
    public static let maxPixelValue = 1_000_000
    public static let maxBytesValue = 1 << 40
    public static let maxTextLength = 100

    /// False for values out of range (e.g. from a hand-edited preset); such conditions are dropped on load.
    public var isValid: Bool { check.isValid }

    public func matches(_ facts: ItemFacts) -> Bool {
        var timedOut = false
        return matches(facts, timedOut: &timedOut)
    }

    /// Whether the condition holds. A check whose value the file doesn't have (no date taken, no ISO, no camera, …)
    /// is false in both forms: "is not before 2020" doesn't match an undated file. Only the explicit presence
    /// checks ("has no date taken", "is missing", "has no location") match missing values.
    public func matches(_ facts: ItemFacts, timedOut: inout Bool) -> Bool {
        guard check.hasValue(in: facts) else { return false }
        var stopped = false
        let result = check.matches(facts, timedOut: &stopped)
        if stopped {
            timedOut = true
            return false
        }
        return result != negated
    }

    /// The same condition, negated the other way.
    public var inverted: Condition { Condition(check, negated: !negated) }

    var needs: FactNeeds { check.needs }

    // The checks that existed before negation, so code and tests read as before.
    public static func longestEdge(_ comparison: Comparison, _ value: Int) -> Condition {
        Condition(.longestEdge(comparison, value))
    }
    public static func width(_ comparison: Comparison, _ value: Int) -> Condition { Condition(.width(comparison, value)) }
    public static func height(_ comparison: Comparison, _ value: Int) -> Condition { Condition(.height(comparison, value)) }
    public static func fileSize(_ comparison: Comparison, bytes: Int) -> Condition {
        Condition(.fileSize(comparison, bytes: bytes))
    }
    public static func format(_ match: FormatMatch) -> Condition { Condition(.format(match)) }
    public static func hasTransparency(_ wanted: Bool) -> Condition { Condition(.hasTransparency(wanted)) }
    public static func orientation(_ orientation: Orientation) -> Condition { Condition(.orientation(orientation)) }
    public static func hasGPS(_ wanted: Bool) -> Condition { Condition(.hasGPS(wanted)) }
    public static func camera(contains text: String) -> Condition { Condition(.camera(contains: text)) }

    private enum NegationKey: String, CodingKey { case not }

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: NegationKey.self), keyed.contains(.not) {
            check = try keyed.decode(ConditionCheck.self, forKey: .not)
            negated = true
        } else {
            check = try ConditionCheck(from: decoder)
            negated = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        if negated {
            var keyed = encoder.container(keyedBy: NegationKey.self)
            try keyed.encode(check, forKey: .not)
        } else {
            try check.encode(to: encoder)
        }
    }
}

/// An if/then/else step: its conditions are tested against the source file's facts (not the image part-way
/// through the pipeline), and the chosen branch's actions replace the step for that image.
public struct ConditionalStep: Codable, Equatable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable {
        case all, any
    }

    public static let maxConditions = 10
    /// Actions per branch; a longer branch (hand-edited) keeps its first 20.
    public static let maxActions = 20
    public static let skippedReason = "Skipped by a condition"
    public static let copiedNote = "Copied unchanged"
    public static let convertedForPrivacyNote = "Converted instead of copied to remove metadata"
    public static let convertedForMetadataEditsNote = "Converted instead of copied to apply this image's metadata changes"
    public static let ignoredForCopyPrefix = "Ignored for a copied original: "
    /// A copy converted for a Redact step or the metadata removals runs only the Redact steps.
    public static let notAppliedToConversionPrefix = "Not applied to the converted copy: "
    /// Conditions found inside this step's branches and left out on load (`Pipeline.loadNotes` says so).
    public internal(set) var droppedNested = NestedConditionCount()

    /// The load note for the conditions `steps`' condition steps left out of their branches on load (none: empty).
    static func nestedNotes(in steps: [PipelineStep]) -> [String] {
        let nested = steps.reduce(0) { total, step in
            guard case .condition(let condition) = step.operation else { return total }
            return total + condition.droppedNested.count
        }
        return nested > 0 ? [nestedConditionNote(count: nested)] : []
    }

    /// The load note for conditions found inside a condition's branch (conditions can't be nested).
    public static func nestedConditionNote(count: Int) -> String {
        count == 1 ? "A condition inside another condition's branch was left out (conditions can't be nested)"
            : "\(count) conditions inside other conditions' branches were left out (conditions can't be nested)"
    }

    public var match: Match
    /// 1...10 conditions.
    public var conditions: [Condition]
    public var then: [ConditionalAction]
    public var otherwise: [ConditionalAction]

    public init(match: Match = .all, conditions: [Condition] = [.longestEdge(.greaterThan, 2048)],
                then: [ConditionalAction] = [], otherwise: [ConditionalAction] = []) {
        self.match = match
        self.conditions = conditions
        self.then = then
        self.otherwise = otherwise
    }

    public func matches(_ facts: ItemFacts) -> Bool {
        var timedOut = false
        return matches(facts, timedOut: &timedOut)
    }

    /// As `matches`, setting `timedOut` when a name pattern was stopped for taking too long (it counts as no
    /// match). Every condition is evaluated in order until the result is known.
    public func matches(_ facts: ItemFacts, timedOut: inout Bool) -> Bool {
        switch match {
        case .all:
            guard !conditions.isEmpty else { return false }
            for condition in conditions where !condition.matches(facts, timedOut: &timedOut) { return false }
            return true
        case .any:
            for condition in conditions where condition.matches(facts, timedOut: &timedOut) { return true }
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case match, conditions, then, otherwise
    }

    /// Lenient like the rest of a pipeline: unreadable or invalid conditions and actions are dropped; a nested
    /// condition is dropped without being read (`BranchAction`) and counted in `droppedNested`. More than 10
    /// conditions, or none left, rejects the whole step; a branch keeps at most 20 actions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = (try? container.decodeIfPresent(Match.self, forKey: .match)) ?? .all
        let raw = try container.decodeIfPresent([Lossy<Condition>].self, forKey: .conditions) ?? []
        guard raw.count <= Self.maxConditions else {
            throw DecodingError.dataCorruptedError(forKey: .conditions, in: container,
                                                   debugDescription: "More than \(Self.maxConditions) conditions")
        }
        conditions = raw.compactMap(\.value).filter(\.isValid)
        guard !conditions.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .conditions, in: container, debugDescription: "No conditions")
        }
        let thenRaw = try container.decodeIfPresent([BranchAction].self, forKey: .then) ?? []
        let otherwiseRaw = try container.decodeIfPresent([BranchAction].self, forKey: .otherwise) ?? []
        then = Array(thenRaw.compactMap(\.value).filter(\.isValid).prefix(Self.maxActions))
        otherwise = Array(otherwiseRaw.compactMap(\.value).filter(\.isValid).prefix(Self.maxActions))
        droppedNested = NestedConditionCount((thenRaw + otherwiseRaw).filter(\.isNestedCondition).count)
    }
}

/// How many nested conditions decoding left out (not saved; never makes two steps unequal).
public struct NestedConditionCount: Equatable, Sendable {
    public var count: Int

    public init(_ count: Int = 0) {
        self.count = count
    }

    public static func == (lhs: NestedConditionCount, rhs: NestedConditionCount) -> Bool { true }
}

/// One branch action as read: nil when unreadable. A step holding another condition is recognised by its keys
/// and never decoded, so a deeply nested file can't recurse (and overflow a worker thread's stack).
private struct BranchAction: Decodable {
    let value: ConditionalAction?
    let isNestedCondition: Bool

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static let step = Key(stringValue: "step"), payload = Key(stringValue: "_0")
        static let operation = Key(stringValue: "operation"), condition = Key(stringValue: "condition")
    }

    init(from decoder: Decoder) throws {
        isNestedCondition = Self.holdsCondition(decoder)
        value = isNestedCondition ? nil : try? ConditionalAction(from: decoder)
    }

    /// True for `{"step": {"_0": {"operation": {"condition": …}}}}`, looked at without decoding the condition.
    private static func holdsCondition(_ decoder: Decoder) -> Bool {
        guard let action = try? decoder.container(keyedBy: Key.self), action.contains(.step),
              let step = try? action.nestedContainer(keyedBy: Key.self, forKey: .step),
              let payload = try? step.nestedContainer(keyedBy: Key.self, forKey: .payload),
              let operation = try? payload.nestedContainer(keyedBy: Key.self, forKey: .operation)
        else { return false }
        return operation.contains(.condition)
    }
}

/// Decodes an element or nil, so one bad element doesn't fail its array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
