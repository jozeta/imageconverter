import Foundation

/// The metadata fields the editor names; anything else is an allowlisted custom key.
public enum NamedMetadataField: String, Codable, CaseIterable, Sendable {
    case cameraMake, cameraModel, lens, iso, focalLength, aperture, shutterSpeed
    case artist, copyright, title, description, keywords, software

    public var displayName: String {
        switch self {
        case .cameraMake: return "camera make"
        case .cameraModel: return "camera model"
        case .lens: return "lens"
        case .iso: return "ISO"
        case .focalLength: return "focal length"
        case .aperture: return "aperture"
        case .shutterSpeed: return "shutter speed"
        case .artist: return "artist"
        case .copyright: return "copyright"
        case .title: return "title"
        case .description: return "description"
        case .keywords: return "keywords"
        case .software: return "software"
        }
    }

    /// Numbers can also be compared (more than, at most …).
    public var isNumeric: Bool { [.iso, .focalLength, .aperture, .shutterSpeed].contains(self) }

    /// The unit after a number in the editor and summary ("mm", "s"); empty for none.
    public var unit: String {
        switch self {
        case .focalLength: return "mm"
        case .shutterSpeed: return "s"
        default: return ""
        }
    }

    /// Artist, copyright, title, description and keywords can live only in XMP.
    var mayNeedXMP: Bool { [.artist, .copyright, .title, .description, .keywords].contains(self) }
}

/// One metadata field to test: a named one, or an allowlisted EXIF/IPTC/XMP key (`MetadataFields.writable`).
public enum MetadataSubject: Codable, Hashable, Sendable {
    case named(NamedMetadataField)
    case custom(MetadataNamespace, String)

    public var isValid: Bool {
        if case .custom(let namespace, let key) = self { return MetadataFields.isWritable(namespace, key) }
        return true
    }

    public var isNumeric: Bool {
        if case .named(let field) = self { return field.isNumeric }
        return false
    }

    public var displayName: String {
        switch self {
        case .named(let field): return field.displayName
        case .custom(let namespace, let key): return "\(namespace.rawValue.uppercased()) \(key)"
        }
    }

    var needsXMP: Bool {
        switch self {
        case .named(let field): return field.mayNeedXMP
        case .custom(let namespace, _): return namespace == .xmp
        }
    }
}

/// How a metadata condition tests its field.
public enum MetadataOperation: String, Codable, CaseIterable, Sendable {
    case equals, contains, exists, missing, greaterThan, lessThan, atLeast, atMost

    /// Numbers only.
    public var comparison: Comparison? {
        switch self {
        case .greaterThan: return .greaterThan
        case .lessThan: return .lessThan
        case .atLeast: return .atLeast
        case .atMost: return .atMost
        default: return nil
        }
    }

    /// Exists and missing take no value.
    public var takesValue: Bool { self != .exists && self != .missing }

    public var phrase: String {
        switch self {
        case .equals: return "is"
        case .contains: return "contains"
        case .exists: return "is present"
        case .missing: return "is missing"
        default: return comparison?.phrase ?? ""
        }
    }

    public var negatedPhrase: String {
        switch self {
        case .equals: return "is not"
        case .contains: return "does not contain"
        case .exists: return "is missing"
        case .missing: return "is present"
        case .greaterThan: return "is not more than"
        case .lessThan: return "is not less than"
        case .atLeast: return "is not at least"
        case .atMost: return "is not at most"
        }
    }
}

/// `lens contains "50mm"`, `ISO is more than 1600`, `copyright is missing`.
public struct MetadataTest: Codable, Equatable, Sendable {
    public var subject: MetadataSubject
    public var operation: MetadataOperation
    public var value: String

    public init(_ subject: MetadataSubject, _ operation: MetadataOperation, _ value: String = "") {
        self.subject = subject
        self.operation = operation
        self.value = value
    }

    public var isValid: Bool {
        guard subject.isValid, value.count <= Condition.maxTextLength else { return false }
        if operation.comparison != nil { return subject.isNumeric && Self.number(value) != nil }
        if operation.takesValue { return !value.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    /// A number as typed: `2.8`, `1/250` (shutter speed), `100`; nil when it isn't one.
    public static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom != 0 {
            return top / bottom
        }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// Whether the field's values (one or more, e.g. keywords) pass.
    public func matches(_ values: [String]) -> Bool {
        let present = values.filter { !$0.isEmpty }
        switch operation {
        case .exists: return !present.isEmpty
        case .missing: return present.isEmpty
        case .equals:
            let wanted = value.trimmingCharacters(in: .whitespaces)
            if subject.isNumeric, let number = Self.number(wanted) {
                return present.compactMap(Self.number).contains { abs($0 - number) < 1e-9 * max(1, abs(number)) }
            }
            return present.contains { $0.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        case .contains:
            let wanted = value.trimmingCharacters(in: .whitespaces)
            return !wanted.isEmpty && present.contains { $0.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        case .greaterThan, .lessThan, .atLeast, .atMost:
            guard let comparison = operation.comparison, let limit = Self.number(value) else { return false }
            return present.compactMap(Self.number).contains { comparison.test($0, limit) }
        }
    }
}
