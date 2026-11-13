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
}
