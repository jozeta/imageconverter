import Foundation
import ImageIO

/// A field the metadata panel can set on one image's outputs: the standard fields the Metadata step sets, the
/// rating, and the allowlisted custom fields (`MetadataFields.writable`).
public enum MetadataOverrideField: Hashable, Sendable {
    case title, description, creator, copyright, keywords, location, dateTaken, rating
    case custom(MetadataNamespace, String)

    /// Every standard field, in the panel's order (custom fields follow `MetadataFields.writable`).
    public static let standard: [MetadataOverrideField] = [
        .title, .description, .keywords, .creator, .copyright, .dateTaken, .location, .rating,
    ]

    /// Every field that can be added, in display order: the standard ones, then the custom ones whose key no
    /// standard field already writes.
    public static var all: [MetadataOverrideField] {
        let covered: Set<String> = [
            "exif:ImageDescription", "exif:Artist", "exif:Copyright", "iptc:ObjectName", "iptc:Byline",
            "iptc:CopyrightNotice", "iptc:CaptionAbstract", "xmp:dc:title", "xmp:dc:creator", "xmp:dc:description",
            "xmp:dc:rights",
        ]
        let custom = MetadataNamespace.allCases.flatMap { namespace in
            (MetadataFields.writable[namespace] ?? []).compactMap { key -> MetadataOverrideField? in
                covered.contains("\(namespace.rawValue):\(key)") ? nil : .custom(namespace, key)
            }
        }
        return standard + custom
    }

    public var label: String {
        switch self {
        case .title: return "Title"
        case .description: return "Description"
        case .creator: return "Creator"
        case .copyright: return "Copyright"
        case .keywords: return "Keywords"
        case .location: return "GPS position"
        case .dateTaken: return "Date taken"
        case .rating: return "Rating"
        case let .custom(namespace, key): return "\(key) (\(namespace.rawValue.uppercased()))"
        }
    }

    /// The kind of value the editor asks for.
    public var valueKind: MetadataOverrideValue.Kind {
        switch self {
        case .keywords: return .keywords
        case .location: return .location
        case .dateTaken: return .date
        case .rating: return .rating
        default: return .text
        }
    }
}

/// What an override does to a field.
public enum MetadataOverrideValue: Hashable, Sendable {
    case text(String)
    case keywords([String])
    /// Latitude and longitude in degrees, altitude in metres.
    case location(latitude: Double, longitude: Double, altitude: Double?)
    /// Written as wall time in the file's own time zone, like the Metadata step's "Set date".
    case date(Date)
    /// -1 (rejected) … 5 stars, written to XMP `xmp:Rating`.
    case rating(Int)
    /// The field is removed from every place it is stored.
    case removed

    public enum Kind: Sendable { case text, keywords, location, date, rating }

    /// `text` without bidirectional embedding, override and isolate controls (an edit pre-filled with a hostile
    /// source value would otherwise write them back invisibly).
    static func withoutBidiControls(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }))
    }

    /// The text of a `.text` value (nil for the others).
    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// The value cleaned for writing (sanitised text, normalised keywords), or nil when it can't be written
    /// (empty text, no keywords, an out-of-range position, date or rating).
    public var validated: MetadataOverrideValue? {
        switch self {
        case .text(let text):
            let clean = Self.withoutBidiControls(MetadataFields.sanitized(text))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : .text(clean)
        case .keywords(let list):
            let clean = MetadataFields.normalizedKeywords(list.map(Self.withoutBidiControls))
            return clean.isEmpty ? nil : .keywords(clean)
        case let .location(latitude, longitude, altitude):
            return LocationEdit.isValid(latitude: latitude, longitude: longitude, altitude: altitude) ? self : nil
        case .date(let date):
            // Years 1...9999, as the Metadata step's saved date allows.
            let interval = date.timeIntervalSinceReferenceDate
            return interval.isFinite && (-63_082_281_600...252_423_993_599).contains(interval) ? self : nil
        case .rating(let stars):
            return (-1...5).contains(stars) ? self : nil
        case .removed:
            return self
        }
    }
}

/// Where a metadata value is stored: a key of an ImageIO property dictionary (`{Exif}`, `{GPS}`, …), a whole
/// dictionary, or a top-level XMP tag (`prefix:name`). Also the id of a row in the metadata panel.
public enum MetadataPath: Hashable, Sendable {
    case property(dictionary: String, key: String)
    case dictionary(String)
    case xmp(String)

    public var id: String {
        switch self {
        case let .property(dictionary, key): return "\(dictionary).\(key)"
        case .dictionary(let dictionary): return dictionary
        case .xmp(let path): return "xmp:\(path)"
        }
    }
}

/// One image's metadata changes from the metadata panel. They apply to that image's outputs only, never to the
/// original, and live with the batch (not in presets, jobs or the CLI).
///
/// Precedence: they are applied after the Metadata step (and any condition's metadata settings). A field that
/// is set wins over the step (even one the step removes); a field that is removed is removed even when the step
/// keeps or sets it. Everything the step removes that isn't set here stays removed. With the step off, the
/// overrides still apply: the image's metadata is written as it is, with these changes.
public struct MetadataOverrides: Hashable, Sendable {
    /// Fields set or removed.
    public internal(set) var fields: [MetadataOverrideField: MetadataOverrideValue] = [:]
    /// Other fields removed (ones the panel can't edit, e.g. a lens serial number or an XMP history).
    public internal(set) var removedPaths: Set<MetadataPath> = []

    public init() {}

    public var isEmpty: Bool { fields.isEmpty && removedPaths.isEmpty }
    /// How many changes there are (for the badge's accessibility label).
    public var count: Int { fields.count + removedPaths.count }

    /// Sets `field` to `value` (validated; false when the value can't be written, which changes nothing).
    @discardableResult
    public mutating func set(_ field: MetadataOverrideField, to value: MetadataOverrideValue) -> Bool {
        guard let clean = value.validated else { return false }
        if case let .custom(namespace, key) = field, !MetadataFields.isWritable(namespace, key) { return false }
        fields[field] = clean
        // Setting a field brings back what a removal of one of its places took away.
        removedPaths.subtract(Self.paths(of: field))
        return true
    }

    /// Removes the field at `path`: the editable field it belongs to everywhere, else just that path.
    public mutating func remove(_ path: MetadataPath) {
        if let field = MetadataInspection.editableField(for: path) {
            fields[field] = .removed
        } else {
            removedPaths.insert(path)
        }
    }

    /// Undoes every change to `field`.
    public mutating func revert(_ field: MetadataOverrideField) { fields[field] = nil }

    /// Undoes the change to the row at `path` (its editable field, or the path's removal).
    public mutating func revert(_ path: MetadataPath) {
        if let field = MetadataInspection.editableField(for: path) { fields[field] = nil }
        removedPaths.remove(path)
    }

    /// Whether the row at `path` is changed (its field set or removed, or the path removed).
    public func isChanged(_ path: MetadataPath) -> Bool {
        if let field = MetadataInspection.editableField(for: path), fields[field] != nil { return true }
        return removedPaths.contains(path)
    }

    /// Whether the row at `path` is removed from the outputs.
    public func isRemoved(_ path: MetadataPath) -> Bool {
        if let field = MetadataInspection.editableField(for: path) {
            if fields[field] == .removed { return true }
            if fields[field] != nil { return false }
        }
        if removedPaths.contains(path) || coveredByRemoval(path) { return true }
        // A set position replaces the whole GPS dictionary: the old altitude, time stamp and the rest go.
        if case .location? = fields[.location], case .property(let dictionary, _) = path,
           dictionary == Self.gpsKey { return true }
        return false
    }

    private static let gpsKey = kCGImagePropertyGPSDictionary as String

    /// Whether a wider removal takes `path` with it: a removed dictionary (the GPS position removes all of `{GPS}`)
    /// or the date taken (every date field, `datePaths`).
    private func coveredByRemoval(_ path: MetadataPath) -> Bool {
        if fields[.dateTaken] == .removed, Self.datePaths.contains(path) { return true }
        guard case .property(let dictionary, _) = path else { return false }
        if dictionary == Self.gpsKey, fields[.location] == .removed { return true }
        return removedPaths.contains(.dictionary(dictionary))
    }

    // MARK: Applying

    /// The places a field is stored, as the panel lists them.
    static func paths(of field: MetadataOverrideField) -> [MetadataPath] {
        MetadataInspection.editableMap.filter { $0.value == field }.map(\.key)
    }

    /// `options` (the step's, after conditions) with the set and removed standard and custom fields written into
    /// it. An inactive step becomes one that keeps everything, so the overrides still apply.
    func applied(to options: MetadataOptions) -> MetadataOptions {
        guard !isEmpty else { return options }
        var result = options.isActive ? options : MetadataOptions(isEnabled: true, location: .keep)
        for (field, value) in fields { Self.write(value, to: field, in: &result) }
        return result
    }

    private static func write(_ value: MetadataOverrideValue, to field: MetadataOverrideField,
                              in result: inout MetadataOptions) {
        // Text fields: a value sets it everywhere the step would, a removal clears it (empty text).
        if let keyPath = textFields[field] {
            result[keyPath: keyPath] = value == .removed ? "" : value.text
            return
        }
        switch (field, value) {
        case (.keywords, .keywords(let list)):
            result.keywords = list
            result.keywordsMode = .replace
        case (.keywords, .removed):
            result.keywords = []
            result.keywordsMode = .replace
        case let (.location, .location(latitude, longitude, altitude)):
            // The step's removal of the place names stays: only the position is set.
            if result.removesLocationEntirely { result.removePlaceNames = true }
            result.location = .set(latitude: latitude, longitude: longitude, altitude: altitude)
        case (.dateTaken, .date(let date)): result.dateTaken = .set(date)
        case let (.custom(namespace, key), _):
            // Set: replaces the step's value for the field; removed: the step doesn't write it (`finish` strips it).
            result.custom.removeAll { $0.namespace == namespace && $0.key == key }
            if let text = value.text { result.custom.append(MetadataField(namespace: namespace, key: key, value: text)) }
        default: break // the position, date and rating removed, the rating set: `finish`
        }
    }

    private static let textFields: [MetadataOverrideField: WritableKeyPath<MetadataOptions, String?>] = [
        .title: \.title, .description: \.description, .creator: \.artist, .copyright: \.copyright,
    ]

    /// The removals and the rating, on the finished output properties (after `MetadataOps.output`).
    func finish(_ properties: [String: Any]) -> [String: Any] {
        guard !isEmpty else { return properties }
        var props = properties
        let xmp = (props[MetadataOps.xmpPropertyKey] as? OutputXMP).flatMap { CGImageMetadataCreateMutableCopy($0.metadata) }
        var paths = removedPaths
        for (field, value) in fields where value == .removed {
            switch field {
            case .location: paths.insert(.dictionary(kCGImagePropertyGPSDictionary as String))
            case .dateTaken: paths.formUnion(Self.datePaths)
            case .rating: paths.insert(.xmp("xmp:Rating"))
            case let .custom(namespace, key): paths.formUnion(Self.customPaths(namespace, key))
            default: break
            }
        }
        for path in paths { Self.remove(path, from: &props, xmp: xmp) }
        if case .rating(let stars)? = fields[.rating], let xmp {
            CGImageMetadataRegisterNamespaceForPrefix(xmp, kCGImageMetadataNamespaceXMPBasic, "xmp" as CFString, nil)
            CGImageMetadataSetValueWithPath(xmp, nil, "xmp:Rating" as CFString, String(stars) as CFString)
        }
        if let xmp { props[MetadataOps.xmpPropertyKey] = OutputXMP(metadata: xmp) }
        return props
    }

    /// Every place the date taken is stored.
    static let datePaths: [MetadataPath] = {
        let exif = kCGImagePropertyExifDictionary as String
        let iptc = kCGImagePropertyIPTCDictionary as String
        return MetadataDates.exifDateFamily.map { MetadataPath.property(dictionary: exif, key: $0) }
            + MetadataDates.iptcDateFamily.map { MetadataPath.property(dictionary: iptc, key: $0) }
            + [.property(dictionary: kCGImagePropertyTIFFDictionary as String, key: kCGImagePropertyTIFFDateTime as String),
               .property(dictionary: kCGImagePropertyPNGDictionary as String, key: kCGImagePropertyPNGCreationTime as String)]
            + MetadataDates.xmpPaths.map { MetadataPath.xmp($0) }
    }()

    static func customPaths(_ namespace: MetadataNamespace, _ key: String) -> [MetadataPath] {
        switch namespace {
        case .exif:
            guard let target = MetadataFields.exifTargets[key] else { return [] }
            return [.property(dictionary: target.dictionary as String, key: target.key as String)]
        case .iptc:
            guard let target = MetadataFields.iptcTargets[key] else { return [] }
            return [.property(dictionary: kCGImagePropertyIPTCDictionary as String, key: target.key as String)]
        case .xmp:
            return [.xmp(key)]
        }
    }

    /// Removes `path` from the property dictionaries and, for a dictionary key, its XMP twin.
    private static func remove(_ path: MetadataPath, from props: inout [String: Any], xmp: CGMutableImageMetadata?) {
        switch path {
        case let .property(dictionary, key):
            if var dict = props[dictionary] as? [String: Any] {
                dict.removeValue(forKey: key)
                MetadataOps.store(dict, at: dictionary, in: &props)
            }
            if let xmp, let tag = CGImageMetadataCopyTagMatchingImageProperty(xmp, dictionary as CFString, key as CFString),
               let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) {
                CGImageMetadataRemoveTagWithPath(xmp, nil, "\(prefix):\(name)" as CFString)
            }
        case .dictionary(let dictionary):
            props.removeValue(forKey: dictionary)
            // The GPS position also lives in XMP outside the EXIF mirrors (e.g. a vendor schema).
            if let xmp, dictionary == kCGImagePropertyGPSDictionary as String { removeGPSTags(from: xmp) }
        case .xmp(let tagPath):
            if let xmp { CGImageMetadataRemoveTagWithPath(xmp, nil, tagPath as CFString) }
        }
    }
}

extension MetadataOverrides {
    private static func removeGPSTags(from xmp: CGMutableImageMetadata) {
        let tags = CGImageMetadataCopyTags(xmp) as? [CGImageMetadataTag] ?? []
        for tag in tags {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  ["gps", "latitude", "longitude", "altitude"].contains(where: name.lowercased().contains) else { continue }
            CGImageMetadataRemoveTagWithPath(xmp, nil, "\(prefix):\(name)" as CFString)
        }
        // And location structures holding coordinates (IPTC Extension LocationCreated/LocationShown).
        MetadataOps.removeTagsHoldingGPS(from: xmp)
    }
}

extension Pipeline {
    /// The Metadata step's options with this image's metadata overrides written in (see `MetadataOverrides`).
    /// What the outputs are written with; `metadata` stays the step's own.
    public var effectiveMetadata: MetadataOptions { metadataOverrides.applied(to: metadata) }

    /// This pipeline with `overrides` for the one image it is used for.
    public func withMetadataOverrides(_ overrides: MetadataOverrides) -> Pipeline {
        var copy = self
        copy.metadataOverrides = overrides
        return copy
    }
}
