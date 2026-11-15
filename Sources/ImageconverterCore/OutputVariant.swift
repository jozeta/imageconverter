import Foundation

/// How an extra output is resized after the pipeline's own steps. Shrink only, except a percentage above 100.
public enum VariantResize: Codable, Equatable, Sendable {
    case longestEdge(Int)
    case maxWidth(Int)
    case maxHeight(Int)
    /// Scales both sides; above 100 enlarges.
    case percent(Double)

    public static let pixelRange = 1...100_000
    public static let percentRange: ClosedRange<Double> = 1...1000

    /// False for a size outside the ranges (a hand-edited file); such a resize is dropped on load.
    public var isValid: Bool {
        switch self {
        case .longestEdge(let pixels), .maxWidth(let pixels), .maxHeight(let pixels):
            return Self.pixelRange.contains(pixels)
        case .percent(let value):
            return value.isFinite && Self.percentRange.contains(value)
        }
    }

    /// The resize step this stands for (Lanczos, no padding).
    public var resizeOptions: ResizeOptions {
        switch self {
        case .longestEdge(let pixels): return ResizeOptions(mode: .longestEdge(pixels))
        case .maxWidth(let pixels): return ResizeOptions(mode: .maxWidth(pixels))
        case .maxHeight(let pixels): return ResizeOptions(mode: .maxHeight(pixels))
        case .percent(let value): return ResizeOptions(mode: .percent(value), allowEnlarge: value > 100)
        }
    }

    /// "longest edge 400 px", "50 %".
    public var summary: String {
        switch self {
        case .longestEdge(let pixels): return "longest edge \(pixels) px"
        case .maxWidth(let pixels): return "max width \(pixels) px"
        case .maxHeight(let pixels): return "max height \(pixels) px"
        case .percent(let value):
            return "\(value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)) %"
        }
    }
}

/// One more file written for every image, next to the primary output: the same processed image (pipeline and
/// metadata applied once), optionally resized, then encoded with its own settings, named `<name><suffix>.<ext>`.
/// An extra output is always a new file: it never replaces or trashes anything, in any output mode.
public struct OutputVariant: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The label shown in the app and the report ("Thumbnail").
    public var name: String
    public var settings: OutputSettings
    /// Nil: the pipeline's own size.
    public var resize: VariantResize?
    /// Added to the base name; required and distinct per output (see `problems(in:)`).
    public var nameSuffix: String
    /// A folder template (rename tokens, `/` between folders) under the primary output's folder; nil for none.
    public var subfolder: String?

    /// At most this many extra outputs per pipeline.
    public static let maxCount = 8
    public static let defaultSuffix = "_thumb"
    public static let maxNameLength = 40
    public static let maxSuffixLength = 32

    public init(id: UUID = UUID(), name: String = "Thumbnail", settings: OutputSettings = OutputSettings(quality: 0.7),
                resize: VariantResize? = .longestEdge(400), nameSuffix: String = OutputVariant.defaultSuffix,
                subfolder: String? = nil) {
        self.id = id
        self.name = name
        self.settings = settings
        self.resize = resize
        self.nameSuffix = nameSuffix
        self.subfolder = subfolder
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, settings, resize, nameSuffix, subfolder
    }

    /// Lenient: missing fields take their defaults, an invalid resize or subfolder is dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        let label = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Output"
        name = String(label.prefix(Self.maxNameLength))
        // Settings that are there but can't be read (e.g. a format from a newer version) fail the output: it is
        // left out with a note instead of quietly becoming a JPEG.
        settings = try container.decodeIfPresent(OutputSettings.self, forKey: .settings) ?? OutputSettings()
        let size = try? container.decodeIfPresent(VariantResize.self, forKey: .resize)
        resize = size?.isValid == true ? size : nil
        nameSuffix = (try? container.decodeIfPresent(String.self, forKey: .nameSuffix)) ?? ""
        let folder = try? container.decodeIfPresent(String.self, forKey: .subfolder)
        subfolder = folder.flatMap { Self.isUsableSubfolder($0) ? $0 : nil }
    }

    /// The suffix as it goes into file names: path separators become `-`, control, bidi and zero-width characters
    /// go, surrounding spaces are trimmed, at most `maxSuffixLength` characters. Empty when nothing is left.
    public static func sanitizedSuffix(_ text: String) -> String {
        let cleaned = RenameTemplate.cleanScalars(text).trimmingCharacters(in: .whitespaces)
        let visible = cleaned.unicodeScalars.contains {
            !$0.properties.isWhitespace && $0.properties.generalCategory != .format
        }
        return visible ? String(cleaned.prefix(maxSuffixLength)) : ""
    }

    /// This output's suffix, sanitised.
    public var cleanSuffix: String { Self.sanitizedSuffix(nameSuffix) }

    /// The label, or the format and suffix when it is blank.
    public var displayName: String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "\(settings.format.displayName) \(cleanSuffix)" : label
    }

    /// The subfolder template when it names a folder.
    public var effectiveSubfolder: String? {
        subfolder.flatMap { Self.isUsableSubfolder($0) ? $0 : nil }
    }

    private static func isUsableSubfolder(_ template: String) -> Bool {
        !SubfolderTemplate.isBlank(template) && template.count <= RenameTemplate.maxLength
    }

    // MARK: Validation

    public static let emptySuffixProblem = "Add a name suffix, so this file can't replace the main output"
    public static let duplicateSuffixProblem = "Another output already uses this suffix"
    public static let tooManyProblem = "At most \(maxCount) extra outputs"

    /// What is wrong with each output, by id (empty when all can run): an empty suffix, a suffix an earlier output
    /// already uses (compared case-insensitively after sanitising), or more than `maxCount` outputs.
    public static func problems(in variants: [OutputVariant]) -> [UUID: String] {
        var problems: [UUID: String] = [:]
        var seen = Set<String>()
        for (index, variant) in variants.enumerated() {
            let suffix = variant.cleanSuffix
            if index >= maxCount {
                problems[variant.id] = tooManyProblem
            } else if suffix.isEmpty {
                problems[variant.id] = emptySuffixProblem
            } else if !seen.insert(suffix.lowercased()).inserted {
                problems[variant.id] = duplicateSuffixProblem
            }
        }
        return problems
    }

    /// The note for an output that couldn't be read at all.
    static func unreadableNote(_ name: String?) -> String {
        let label = name.map { String($0.prefix(maxNameLength)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return label.isEmpty ? "An extra output couldn't be read and was left out"
            : "Extra output “\(label)” couldn't be read and was left out"
    }

    /// The outputs that can run, in order, and a note for each one left out (`problems(in:)`). An id that repeats
    /// an earlier one (a hand-edited file) gets a new one first, so it is judged on its own.
    public static func validated(_ variants: [OutputVariant]) -> (kept: [OutputVariant], notes: [String]) {
        var variants = variants
        var ids = Set<UUID>()
        for index in variants.indices where !ids.insert(variants[index].id).inserted { variants[index].id = UUID() }
        let problems = problems(in: variants)
        guard !problems.isEmpty else { return (variants, []) }
        var kept: [OutputVariant] = []
        var notes: [String] = []
        for variant in variants {
            if let problem = problems[variant.id] {
                notes.append("Extra output “\(variant.displayName)” was left out: \(problem.lowercasedFirst)")
            } else {
                kept.append(variant)
            }
        }
        return (kept, notes)
    }
}

/// One element of a saved `extraOutputs` list: the output, or nil (with its label if readable) when it can't be read.
struct LossyVariant: Decodable {
    let variant: OutputVariant?
    /// The label of an output that couldn't be read, when at least that could.
    let name: String?

    private enum Keys: String, CodingKey { case name }

    init(from decoder: Decoder) throws {
        variant = try? OutputVariant(from: decoder)
        name = variant == nil ? (try? decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .name)) : nil
    }
}

/// Notes about a pipeline as it was read (e.g. extra outputs left out). Not saved, and never makes two pipelines
/// unequal, so a loaded preset doesn't count as changed.
public struct PipelineLoadNotes: Equatable, Sendable {
    public var notes: [String]

    public init(_ notes: [String] = []) {
        self.notes = notes
    }

    public static func == (lhs: PipelineLoadNotes, rhs: PipelineLoadNotes) -> Bool { true }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
