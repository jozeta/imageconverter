import Foundation
import UniformTypeIdentifiers

/// How a condition compares a number with its limit.
public enum Comparison: String, Codable, CaseIterable, Sendable {
    case greaterThan, lessThan, atLeast, atMost

    public func test(_ value: Int, _ limit: Int) -> Bool {
        switch self {
        case .greaterThan: return value > limit
        case .lessThan: return value < limit
        case .atLeast: return value >= limit
        case .atMost: return value <= limit
        }
    }

    public var symbol: String {
        switch self {
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .atLeast: return "≥"
        case .atMost: return "≤"
        }
    }
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

/// One test against a source file's facts.
public enum Condition: Codable, Equatable, Sendable {
    case longestEdge(Comparison, Int)
    case width(Comparison, Int)
    case height(Comparison, Int)
    case fileSize(Comparison, bytes: Int)
    case format(FormatMatch)
    case hasTransparency(Bool)
    case orientation(Orientation)
    case hasGPS(Bool)
    /// Case-insensitive substring of the camera make or model.
    case camera(contains: String)

    /// Limits for hand-edited presets: sizes in pixels and bytes, and text lengths.
    public static let maxPixelValue = 1_000_000
    public static let maxBytesValue = 1 << 40
    public static let maxTextLength = 100

    /// False for values out of range (e.g. from a hand-edited preset); such conditions are dropped on load.
    public var isValid: Bool {
        switch self {
        case .longestEdge(_, let value), .width(_, let value), .height(_, let value):
            return (0...Self.maxPixelValue).contains(value)
        case .fileSize(_, let bytes):
            return (0...Self.maxBytesValue).contains(bytes)
        case .format(.format):
            return true
        case .format(.type(let identifier)):
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
            return !identifier.isEmpty && identifier.count <= Self.maxTextLength
                && identifier.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        case .camera(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.count <= Self.maxTextLength
        case .hasTransparency, .orientation, .hasGPS:
            return true
        }
    }

    // One case per condition keeps every test in one place.
    // swiftlint:disable:next cyclomatic_complexity
    public func matches(_ facts: ItemFacts) -> Bool {
        switch self {
        case .longestEdge(let comparison, let value): return comparison.test(max(facts.width, facts.height), value)
        case .width(let comparison, let value): return comparison.test(facts.width, value)
        case .height(let comparison, let value): return comparison.test(facts.height, value)
        case .fileSize(let comparison, let bytes): return comparison.test(facts.fileSize, bytes)
        case .format(.format(let format)): return facts.format == format
        case .format(.type(let identifier)):
            if facts.sourceType == identifier { return true }
            guard let source = UTType(facts.sourceType), let wanted = UTType(identifier) else { return false }
            return source.conforms(to: wanted)
        case .hasTransparency(let wanted): return facts.hasAlpha == wanted
        case .orientation(let wanted): return Orientation(width: facts.width, height: facts.height) == wanted
        case .hasGPS(let wanted): return facts.hasGPS == wanted
        case .camera(let text):
            let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return false }
            return [facts.make, facts.model].compactMap { $0 }.contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Only transparency needs the thumbnail scan; everything else is in the header.
    var needsAlphaScan: Bool {
        if case .hasTransparency = self { return true }
        return false
    }
}

/// What a branch of a condition does to one image.
public enum ConditionalAction: Codable, Equatable, Sendable {
    /// An image step, inserted where the condition stands. Never another condition (no nesting).
    case step(PipelineStep)
    /// Replaces the pipeline's output settings for this image.
    case output(OutputSettings)
    /// Replaces the Metadata step's settings for this image (switched on).
    case metadata(MetadataOptions)
    /// Replaces the Rename step's settings for this image (switched on).
    case rename(RenameOptions)
    /// Writes the source's bytes unchanged, with its own extension; nothing is decoded.
    case copyOriginal
    /// Writes nothing; reported as skipped by a condition, not as a failure.
    case skip

    /// False for a nested condition, which is dropped on load.
    public var isValid: Bool {
        if case .step(let step) = self, case .condition = step.operation { return false }
        return true
    }
}

/// An if/then/else step: its conditions are tested against the source file's facts (not the image part-way
/// through the pipeline), and the chosen branch's actions replace the step for that image.
public struct ConditionalStep: Codable, Equatable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable {
        case all, any
    }

    public static let maxConditions = 10
    public static let skippedReason = "Skipped by a condition"
    public static let copiedNote = "Copied unchanged"

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
        switch match {
        case .all: return !conditions.isEmpty && conditions.allSatisfy { $0.matches(facts) }
        case .any: return conditions.contains { $0.matches(facts) }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case match, conditions, then, otherwise
    }

    /// Lenient like the rest of a pipeline: unreadable or invalid conditions and actions (including a nested
    /// condition) are dropped. More than 10 conditions, or none left, rejects the whole step.
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
        then = (try container.decodeIfPresent([Lossy<ConditionalAction>].self, forKey: .then) ?? [])
            .compactMap(\.value).filter(\.isValid)
        otherwise = (try container.decodeIfPresent([Lossy<ConditionalAction>].self, forKey: .otherwise) ?? [])
            .compactMap(\.value).filter(\.isValid)
    }
}

/// Decodes an element or nil, so one bad element doesn't fail its array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// What the batch does with one image after its conditions are resolved.
public enum Disposition: String, Equatable, Sendable {
    case process, copyOriginal, skip
}

/// A pipeline with its condition steps replaced by the branches chosen for one image.
public struct ResolvedPipeline: Equatable, Sendable {
    /// Holds no condition steps.
    public var pipeline: Pipeline
    public var disposition: Disposition

    public init(pipeline: Pipeline, disposition: Disposition = .process) {
        self.pipeline = pipeline
        self.disposition = disposition
    }

    /// "Skipped by a condition" / "Copied unchanged"; nil when processed.
    public var statusNote: String? {
        switch disposition {
        case .process: return nil
        case .copyOriginal: return ConditionalStep.copiedNote
        case .skip: return ConditionalStep.skippedReason
        }
    }
}

extension Pipeline {
    /// True when any enabled step is a condition (only then are a file's facts read).
    public var hasConditions: Bool {
        steps.contains { step in
            if step.isEnabled, case .condition = step.operation { return true }
            return false
        }
    }

    private var conditionsNeedAlphaScan: Bool {
        steps.contains { step in
            guard step.isEnabled, case .condition(let conditional) = step.operation else { return false }
            return conditional.conditions.contains(where: \.needsAlphaScan)
        }
    }

    /// The pipeline for one image: each enabled condition step, in order, is replaced in place by the image
    /// steps of the branch its facts choose; output, metadata and rename overrides apply (later ones win);
    /// skip wins over copying the original, and both win over processing. Disabled condition steps are
    /// dropped. With no facts (an unreadable file), conditions are dropped and the file fails as usual later.
    public func resolved(for facts: ItemFacts?) -> ResolvedPipeline {
        var result = self
        var disposition = Disposition.process
        result.steps = []
        for step in steps {
            guard case .condition(let conditional) = step.operation else {
                result.steps.append(step)
                continue
            }
            guard step.isEnabled, let facts else { continue }
            for action in conditional.matches(facts) ? conditional.then : conditional.otherwise {
                result.apply(action, disposition: &disposition)
            }
        }
        if disposition == .copyOriginal {
            // A copy is the unchanged source: no image steps (so `{width}`/`{height}` give its own size), and
            // its own format where the app knows it (the rename context takes the extension from the file).
            result.steps = []
            if let format = facts?.format { result.output.format = format }
        }
        return ResolvedPipeline(pipeline: result, disposition: disposition)
    }

    private mutating func apply(_ action: ConditionalAction, disposition: inout Disposition) {
        switch action {
        case .step(let inner):
            // Nesting is rejected on load; one built in code is ignored too.
            if case .condition = inner.operation { return }
            steps.append(inner)
        case .output(let settings): output = settings
        case .metadata(var options):
            options.isIncluded = true
            options.isEnabled = true
            metadata = options
        case .rename(var options):
            options.isIncluded = true
            options.isEnabled = true
            rename = options
        case .copyOriginal: if disposition == .process { disposition = .copyOriginal }
        case .skip: disposition = .skip
        }
    }

    /// Resolves for the file at `url`, reading its facts only when there are conditions (and scanning for
    /// transparency only when a condition asks about it, and the image is within `maxPixels`).
    public func resolved(forSource url: URL, maxPixels: Int = ImageLoader.defaultMaxPixels) -> ResolvedPipeline {
        guard hasConditions else { return ResolvedPipeline(pipeline: withoutConditions) }
        return resolved(for: ItemFacts.read(url, scanAlpha: conditionsNeedAlphaScan, maxPixels: maxPixels))
    }

    /// This pipeline without its (disabled) condition steps, so a resolved pipeline never holds one.
    var withoutConditions: Pipeline {
        var copy = self
        copy.steps.removeAll { step in
            if case .condition = step.operation { return true }
            return false
        }
        return copy
    }
}
