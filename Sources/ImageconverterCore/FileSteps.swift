import Foundation

/// What to strip from, and set on, each file's metadata. A nil text field is left as is; a non-nil
/// field is set (an empty string clears it). Removal happens before setting.
public struct MetadataOptions: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var removeAll: Bool
    public var removeLocation: Bool
    public var removeCamera: Bool
    public var artist: String?
    public var copyright: String?
    public var description: String?

    public init(isEnabled: Bool = false, removeAll: Bool = false, removeLocation: Bool = true,
                removeCamera: Bool = false, artist: String? = nil, copyright: String? = nil,
                description: String? = nil) {
        self.isEnabled = isEnabled
        self.removeAll = removeAll
        self.removeLocation = removeLocation
        self.removeCamera = removeCamera
        self.artist = artist
        self.copyright = copyright
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, removeAll, removeLocation, removeCamera, artist, copyright, description
    }

    /// Lenient: a missing field takes its default, so older saved pipelines keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        removeAll = try container.decodeIfPresent(Bool.self, forKey: .removeAll) ?? false
        removeLocation = try container.decodeIfPresent(Bool.self, forKey: .removeLocation) ?? true
        removeCamera = try container.decodeIfPresent(Bool.self, forKey: .removeCamera) ?? false
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

/// How output files are named.
public struct RenameOptions: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var pattern: String
    public var counterStart: Int

    public init(isEnabled: Bool = false, pattern: String = "{name}", counterStart: Int = 1) {
        self.isEnabled = isEnabled
        self.pattern = pattern
        self.counterStart = counterStart
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, pattern, counterStart
    }

    /// Lenient: a missing field takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? "{name}"
        counterStart = try container.decodeIfPresent(Int.self, forKey: .counterStart) ?? 1
    }
}
