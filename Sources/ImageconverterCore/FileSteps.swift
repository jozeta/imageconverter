import Foundation

/// What to strip from, and set on, each file's metadata. A nil text field is left as is; a non-nil
/// field is set (an empty string clears it). Removal happens before setting.
public struct MetadataOptions: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Whether the step is part of the pipeline (added from "+ Add step"). Removing it keeps the settings.
    public var isIncluded: Bool
    /// What the batch, preview and estimate use.
    public var isActive: Bool { isIncluded && isEnabled }
    public var removeAll: Bool
    public var removeLocation: Bool
    public var removeCamera: Bool
    public var artist: String?
    public var copyright: String?
    public var description: String?

    public init(isEnabled: Bool = false, isIncluded: Bool? = nil, removeAll: Bool = false, removeLocation: Bool = true,
                removeCamera: Bool = false, artist: String? = nil, copyright: String? = nil,
                description: String? = nil) {
        self.isEnabled = isEnabled
        self.isIncluded = isIncluded ?? isEnabled
        self.removeAll = removeAll
        self.removeLocation = removeLocation
        self.removeCamera = removeCamera
        self.artist = artist
        self.copyright = copyright
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, isIncluded, removeAll, removeLocation, removeCamera, artist, copyright, description
    }

    /// Lenient: a missing field takes its default, so older saved pipelines keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // Older files had no flag: a step that was switched on stays visible, a switched-off one goes away.
        isIncluded = try container.decodeIfPresent(Bool.self, forKey: .isIncluded) ?? isEnabled
        removeAll = try container.decodeIfPresent(Bool.self, forKey: .removeAll) ?? false
        removeLocation = try container.decodeIfPresent(Bool.self, forKey: .removeLocation) ?? true
        removeCamera = try container.decodeIfPresent(Bool.self, forKey: .removeCamera) ?? false
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

/// One find-and-replace rule of the Rename step.
public struct ReplacementRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var find: String
    public var replace: String
    public var useRegex: Bool

    public init(id: UUID = UUID(), find: String = "", replace: String = "", useRegex: Bool = false) {
        self.id = id
        self.find = find
        self.replace = replace
        self.useRegex = useRegex
    }

    private enum CodingKeys: String, CodingKey { case id, find, replace, useRegex }

    static let fallbackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Lenient: a missing field takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A fixed id keeps two decodes of the same old file equal (preset change tracking compares them).
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? Self.fallbackID
        find = try container.decodeIfPresent(String.self, forKey: .find) ?? ""
        replace = try container.decodeIfPresent(String.self, forKey: .replace) ?? ""
        useRegex = try container.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
    }
}

/// How output files are named.
public struct RenameOptions: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Whether the step is part of the pipeline (added from "+ Add step").
    public var isIncluded: Bool
    public var isActive: Bool { isIncluded && isEnabled }
    public var pattern: String
    public var counterStart: Int
    /// Find and replace rules, applied in order to the rendered name; a rule with an empty `find` does nothing.
    public var replacements: [ReplacementRule]

    /// The counter start is limited to 0...999_999_999 when decoded.
    public static let counterRange = 0...999_999_999
    /// At most this many rules are kept when decoded.
    public static let maxReplacements = 20

    public init(isEnabled: Bool = false, isIncluded: Bool? = nil, pattern: String = "{name}", counterStart: Int = 1,
                replacements: [ReplacementRule] = []) {
        self.isEnabled = isEnabled
        self.isIncluded = isIncluded ?? isEnabled
        self.pattern = pattern
        self.counterStart = counterStart
        self.replacements = replacements
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, isIncluded, pattern, counterStart, replacements
    }

    /// The single-rule keys of older files; read, never written.
    private enum LegacyKeys: String, CodingKey { case findText, replaceText, useRegex }

    /// Lenient: a missing field takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // Older files had no flag: a step that was switched on stays visible, a switched-off one goes away.
        isIncluded = try container.decodeIfPresent(Bool.self, forKey: .isIncluded) ?? isEnabled
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? "{name}"
        let start = try container.decodeIfPresent(Int.self, forKey: .counterStart) ?? 1
        counterStart = min(max(start, Self.counterRange.lowerBound), Self.counterRange.upperBound)
        if let rules = try container.decodeIfPresent([ReplacementRule].self, forKey: .replacements) {
            replacements = Array(rules.prefix(Self.maxReplacements))
            // Rules without an id all got the same fallback; give repeats a position-based id (ForEach needs unique ids).
            var seen = Set<UUID>()
            for index in replacements.indices where !seen.insert(replacements[index].id).inserted {
                replacements[index].id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            }
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let find = try legacy.decodeIfPresent(String.self, forKey: .findText) ?? ""
            let replace = try legacy.decodeIfPresent(String.self, forKey: .replaceText) ?? ""
            let regex = try legacy.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
            replacements = find.isEmpty ? [] : [ReplacementRule(id: ReplacementRule.fallbackID, find: find, replace: replace,
                                                                useRegex: regex)]
        }
    }
}
