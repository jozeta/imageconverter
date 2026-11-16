import Foundation

/// One value the privacy scan found.
public struct PrivacyDetail: Equatable, Hashable, Sendable {
    /// The field's name, e.g. "Body serial number".
    public let field: String
    /// Its value, escaped (`MetadataInspection.display`) and at most `maxLength` characters.
    public let value: String
    /// Where it is stored; the metadata panel's row for it (nil when it has none, e.g. a thumbnail).
    public let path: MetadataPath?

    public static let maxLength = 200

    public init(field: String, value: String, path: MetadataPath?) {
        self.field = field
        self.value = MetadataInspection.display(value, limit: Self.maxLength)
        self.path = path
    }
}
