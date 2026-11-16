import Foundation

/// The run journal keeps each item's metadata panel changes, so a resumed run writes what the user asked for (a
/// removed GPS position stays removed). Decoding is strict: the file is untrusted, and an entry that can't be read
/// (an unknown kind, a field outside the allowlist, an out-of-range value, an over-long path) rejects the whole
/// value, so a journal is never resumed with part of its removals missing.
extension MetadataOverrides: Codable {
    static let maxRemovedPaths = 1_000
    static let maxPathLength = 256

    private enum CodingKeys: String, CodingKey { case fields, removedPaths }

    private struct Entry: Codable {
        let field: StoredField
        let value: StoredValue
    }

    private struct StoredField: Codable {
        var kind: String
        var namespace: String?
        var key: String?
    }

    private struct StoredValue: Codable {
        var kind: String
        var text: String?
        var list: [String]?
        var latitude: Double?
        var longitude: Double?
        var altitude: Double?
        var date: Double?
        var stars: Int?
    }

    private struct StoredPath: Codable {
        var kind: String
        var dictionary: String?
        var key: String?
        var path: String?
    }

    private struct Invalid: Error {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        let entries = try container.decodeIfPresent([Entry].self, forKey: .fields) ?? []
        let paths = try container.decodeIfPresent([StoredPath].self, forKey: .removedPaths) ?? []
        guard entries.count <= MetadataOverrideField.all.count, paths.count <= Self.maxRemovedPaths else {
            throw DecodingError.dataCorruptedError(forKey: .fields, in: container, debugDescription: "Too many entries")
        }
        do {
            for entry in entries {
                let field = try Self.field(entry.field)
                let value = try Self.value(entry.value)
                if value == .removed {
                    fields[field] = .removed
                } else if !set(field, to: value) {
                    throw Invalid()
                }
            }
            for stored in paths { removedPaths.insert(try Self.path(stored)) }
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .fields, in: container,
                                                   debugDescription: "Invalid metadata override")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let entries = fields.map { Entry(field: Self.stored($0.key), value: Self.stored($0.value)) }
            .sorted { "\($0.field.kind)\($0.field.namespace ?? "")\($0.field.key ?? "")"
                < "\($1.field.kind)\($1.field.namespace ?? "")\($1.field.key ?? "")" }
        try container.encode(entries, forKey: .fields)
        try container.encode(removedPaths.sorted { $0.id < $1.id }.map(Self.stored), forKey: .removedPaths)
    }

    // MARK: Fields

    private static let standardKinds: [String: MetadataOverrideField] = [
        "title": .title, "description": .description, "creator": .creator, "copyright": .copyright,
        "keywords": .keywords, "location": .location, "dateTaken": .dateTaken, "rating": .rating,
    ]

    private static func stored(_ field: MetadataOverrideField) -> StoredField {
        if case let .custom(namespace, key) = field {
            return StoredField(kind: "custom", namespace: namespace.rawValue, key: key)
        }
        return StoredField(kind: standardKinds.first { $0.value == field }?.key ?? "")
    }

    private static func field(_ stored: StoredField) throws -> MetadataOverrideField {
        if let field = standardKinds[stored.kind] { return field }
        guard stored.kind == "custom", let namespace = stored.namespace.flatMap(MetadataNamespace.init(rawValue:)),
              let key = stored.key, MetadataFields.isWritable(namespace, key) else { throw Invalid() }
        return .custom(namespace, key)
    }

    // MARK: Values

    private static func stored(_ value: MetadataOverrideValue) -> StoredValue {
        var stored = StoredValue(kind: "")
        switch value {
        case .text(let text): (stored.kind, stored.text) = ("text", text)
        case .keywords(let list): (stored.kind, stored.list) = ("keywords", list)
        case let .location(latitude, longitude, altitude):
            (stored.kind, stored.latitude, stored.longitude, stored.altitude) = ("location", latitude, longitude, altitude)
        case .date(let date): (stored.kind, stored.date) = ("date", date.timeIntervalSinceReferenceDate)
        case .rating(let stars): (stored.kind, stored.stars) = ("rating", stars)
        case .removed: stored.kind = "removed"
        }
        return stored
    }

    private static let readers: [String: @Sendable (StoredValue) -> MetadataOverrideValue?] = [
        "text": { $0.text.map(MetadataOverrideValue.text) },
        "keywords": { $0.list.map(MetadataOverrideValue.keywords) },
        "location": { stored in
            guard let latitude = stored.latitude, let longitude = stored.longitude else { return nil }
            return .location(latitude: latitude, longitude: longitude, altitude: stored.altitude)
        },
        "date": { $0.date.map { .date(Date(timeIntervalSinceReferenceDate: $0)) } },
        "rating": { $0.stars.map(MetadataOverrideValue.rating) },
        "removed": { _ in .removed },
    ]

    private static func value(_ stored: StoredValue) throws -> MetadataOverrideValue {
        guard let value = readers[stored.kind]?(stored) else { throw Invalid() }
        return value
    }

    // MARK: Paths

    private static func stored(_ path: MetadataPath) -> StoredPath {
        switch path {
        case let .property(dictionary, key): return StoredPath(kind: "property", dictionary: dictionary, key: key)
        case .dictionary(let dictionary): return StoredPath(kind: "dictionary", dictionary: dictionary)
        case .xmp(let tag): return StoredPath(kind: "xmp", path: tag)
        }
    }

    private static func path(_ stored: StoredPath) throws -> MetadataPath {
        let parts = [stored.dictionary, stored.key, stored.path].compactMap { $0 }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.count <= maxPathLength }) else { throw Invalid() }
        switch (stored.kind, stored.dictionary, stored.key, stored.path) {
        case let ("property", dictionary?, key?, nil): return .property(dictionary: dictionary, key: key)
        case let ("dictionary", dictionary?, nil, nil): return .dictionary(dictionary)
        case let ("xmp", nil, nil, tag?): return .xmp(tag)
        default: throw Invalid()
        }
    }
}
