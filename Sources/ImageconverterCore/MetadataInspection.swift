import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The groups of the metadata panel, in display order.
public enum MetadataGroup: String, CaseIterable, Sendable {
    case file, camera, location, description, rights, technical, other

    public var title: String {
        switch self {
        case .file: return "File"
        case .camera: return "Camera (EXIF)"
        case .location: return "Location (GPS)"
        case .description: return "Description (IPTC/XMP)"
        case .rights: return "Rights"
        case .technical: return "Technical (TIFF/colour)"
        case .other: return "Other"
        }
    }
}

/// One row of the metadata panel: a value read from the file's header (never its pixels), as plain, escaped text.
public struct MetadataEntry: Identifiable, Hashable, Sendable {
    public let group: MetadataGroup
    public let label: String
    /// Escaped (control and bidirectional characters shown as `<U+…>`), at most `MetadataInspection.maxValueLength`.
    public let value: String
    /// Where it is stored; nil for the file facts (name, size), which aren't metadata.
    public let path: MetadataPath?
    /// The field an edit sets (nil: the row can only be removed, or not changed at all).
    public let field: MetadataOverrideField?
    /// The value an edit starts from.
    public let editValue: MetadataOverrideValue?
    /// Whether the row can be removed from the outputs (structural fields like the pixel size can't).
    public let removable: Bool

    public var id: String { path?.id ?? "file:\(label)" }

    /// Whether `query` (case-insensitive) is in the label, the value or the storage path.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return label.localizedCaseInsensitiveContains(query) || value.localizedCaseInsensitiveContains(query)
            || (path?.id.localizedCaseInsensitiveContains(query) ?? false)
    }
}

/// The metadata of one file, read header-only for the metadata panel.
public struct MetadataInspection: Sendable {
    public let entries: [MetadataEntry]
    /// Why nothing could be read (nil when it was).
    public let failure: String?

    public static let maxValueLength = 10_000
    static let maxListItems = 200

    public init(entries: [MetadataEntry], failure: String? = nil) {
        self.entries = entries
        self.failure = failure
    }

    /// The entries in `group` that match `query`.
    public func entries(in group: MetadataGroup, matching query: String = "") -> [MetadataEntry] {
        entries.filter { $0.group == group && $0.matches(query) }
    }

    /// The fields that can be added: every editable field no row holds yet.
    public var addableFields: [MetadataOverrideField] {
        let present = Set(entries.compactMap(\.field))
        return MetadataOverrideField.all.filter { !present.contains($0) }
    }

    /// The row the privacy panel's link for `path` goes to: the row at that path, else the row of its field.
    /// A path the panel doesn't list (an XMP tag in ImageIO's EXIF mirror namespaces, such as `exif:GPSLatitude` or
    /// `aux:SerialNumber`) lands on the row that stands for it: the GPS position for GPS names, a dictionary row
    /// with the same field name, else the first row of the group the tag belongs to.
    public func entry(for path: MetadataPath) -> MetadataEntry? {
        if let exact = entries.first(where: { $0.path == path }) { return exact }
        if let field = Self.editableField(for: path), let row = entries.first(where: { $0.field == field }) { return row }
        guard case .xmp(let tag) = path else { return nil }
        let name = String(tag.split(separator: ":").last ?? "")
        let lower = name.lowercased()
        if ["gps", "latitude", "longitude", "altitude"].contains(where: lower.contains),
           let position = entries.first(where: { $0.path == .dictionary(kCGImagePropertyGPSDictionary as String) }) {
            return position
        }
        if let same = entries.first(where: { entry in
            if case .property(_, let key)? = entry.path { return key.caseInsensitiveCompare(name) == .orderedSame }
            return false
        }) { return same }
        let group = Self.xmpGroup(path: tag, name: name)
        return entries.first { $0.group == group }
    }

    // MARK: Reading

    /// Reads `url`'s header and metadata (no pixel decode).
    public static func read(_ url: URL) -> MetadataInspection {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any] else {
            return MetadataInspection(entries: [], failure: "The file's metadata couldn't be read")
        }
        var builder = Builder()
        builder.file(url: url, source: source, properties: properties)
        builder.dictionaries(properties)
        builder.xmp(CGImageSourceCopyMetadataAtIndex(source, 0, nil), properties: properties)
        return MetadataInspection(entries: builder.entries)
    }

    private struct Builder {
        var entries: [MetadataEntry] = []
        var fieldsShown: Set<MetadataOverrideField> = []

        mutating func add(_ group: MetadataGroup, _ label: String, _ value: String, path: MetadataPath?,
                          editValue: MetadataOverrideValue? = nil, removable: Bool = true) {
            let field = path.flatMap(MetadataInspection.editableField(for:))
            // One row per editable field (its first place), so an edit or removal shows once.
            if let field, !fieldsShown.insert(field).inserted { return }
            entries.append(MetadataEntry(group: group, label: label, value: MetadataInspection.display(value), path: path,
                                         field: field, editValue: editValue ?? field.map { _ in .text(value) },
                                         removable: removable))
        }

        mutating func file(url: URL, source: CGImageSource, properties: [String: Any]) {
            add(.file, "Name", url.lastPathComponent, path: nil, removable: false)
            if let type = CGImageSourceGetType(source) as String? {
                add(.file, "Kind", UTType(type)?.localizedDescription ?? type, path: nil, removable: false)
            }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                add(.file, "File size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                    path: nil, removable: false)
            }
            if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
               let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
                add(.file, "Dimensions", "\(width) × \(height) pixels", path: nil, removable: false)
            }
            let frames = CGImageSourceGetCount(source)
            if frames > 1 { add(.file, "Frames", "\(frames)", path: nil, removable: false) }
        }

        mutating func dictionaries(_ properties: [String: Any]) {
            for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
                if let dict = value as? [String: Any], key.hasPrefix("{") {
                    dictionary(key, dict, all: properties)
                } else if !(value is [Any]) {
                    // Top-level facts ImageIO derives from the image itself: shown, never removed.
                    add(.technical, MetadataInspection.label(key), MetadataInspection.text(value), path: nil,
                        removable: false)
                }
            }
        }

        private mutating func dictionary(_ key: String, _ dict: [String: Any], all: [String: Any]) {
            let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            if key.hasPrefix("{Maker") {
                add(.camera, "Maker notes (\(name.dropFirst(5)))", "\(dict.count) fields", path: .dictionary(key))
                return
            }
            if key == kCGImagePropertyGPSDictionary as String {
                gps(dict)
                return
            }
            for (field, value) in dict.sorted(by: { $0.key < $1.key }) {
                let path = MetadataPath.property(dictionary: key, key: field)
                let group = MetadataInspection.group(dictionary: key, key: field)
                let structural = MetadataInspection.structural.contains(field) || key == kCGImagePropertyJFIFDictionary as String
                var edit: MetadataOverrideValue?
                switch MetadataInspection.editableField(for: path) {
                case .keywords?: edit = .keywords(MetadataInspection.strings(value))
                case .dateTaken?: edit = MetadataDates.dateTaken(in: all).map { .date($0) }
                default: break
                }
                add(group, MetadataInspection.label(field) + " (\(name))", MetadataInspection.text(value), path: path,
                    editValue: edit ?? (MetadataInspection.editableField(for: path) == nil ? nil
                                        : .text(MetadataInspection.strings(value).joined(separator: ", "))),
                    removable: !structural)
            }
        }

        private mutating func gps(_ dict: [String: Any]) {
            let gpsKey = kCGImagePropertyGPSDictionary as String
            let covered: Set<String> = [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef,
                                        kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef]
                .reduce(into: []) { $0.insert($1 as String) }
            if let position = MetadataInspection.position(dict) {
                add(.location, "GPS position", MetadataInspection.positionText(position), path: .dictionary(gpsKey),
                    editValue: .location(latitude: position.latitude, longitude: position.longitude,
                                         altitude: position.altitude))
            }
            for (field, value) in dict.sorted(by: { $0.key < $1.key }) where !covered.contains(field) {
                add(.location, MetadataInspection.label(field) + " (GPS)", MetadataInspection.text(value),
                    path: .property(dictionary: gpsKey, key: field))
            }
        }

        /// The XMP tags, without ImageIO's twins of the dictionary fields already listed (an IPTC City's
        /// photoshop:City): removing the dictionary field removes its twin too (`MetadataOverrides.finish`).
        mutating func xmp(_ metadata: CGImageMetadata?, properties: [String: Any]) {
            guard let metadata, let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return }
            let twins = MetadataInspection.twinPaths(in: metadata, properties: properties)
            for tag in tags {
                guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
                      !MetadataInspection.mirrorNamespaces.contains(namespace),
                      let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                      let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
                let path = "\(prefix):\(name)"
                if twins.contains(path) { continue }
                let value = MetadataInspection.xmpText(tag)
                var edit: MetadataOverrideValue?
                switch MetadataInspection.editableField(for: .xmp(path)) {
                case .keywords?: edit = .keywords(MetadataInspection.xmpStrings(tag))
                case .rating?: edit = Int(value).map { .rating($0) }
                case .dateTaken?: edit = nil  // the EXIF row, when there is one, carries the date
                default: break
                }
                add(MetadataInspection.xmpGroup(path: path, name: name), path + " (XMP)", value, path: .xmp(path),
                    editValue: edit)
            }
        }
    }
}

// MARK: Editable fields

extension MetadataInspection {
    /// Every storage place an edit can set, with the field it belongs to.
    static let editableMap: [MetadataPath: MetadataOverrideField] = {
        let tiff = kCGImagePropertyTIFFDictionary as String
        let iptc = kCGImagePropertyIPTCDictionary as String
        let png = kCGImagePropertyPNGDictionary as String
        let exif = kCGImagePropertyExifDictionary as String
        func prop(_ dict: String, _ key: CFString) -> MetadataPath { .property(dictionary: dict, key: key as String) }
        var map: [MetadataPath: MetadataOverrideField] = [
            prop(iptc, kCGImagePropertyIPTCObjectName): .title, .xmp("dc:title"): .title,
            prop(png, kCGImagePropertyPNGTitle): .title,
            prop(tiff, kCGImagePropertyTIFFImageDescription): .description,
            prop(iptc, kCGImagePropertyIPTCCaptionAbstract): .description, .xmp("dc:description"): .description,
            prop(png, kCGImagePropertyPNGDescription): .description,
            prop(tiff, kCGImagePropertyTIFFArtist): .creator, prop(iptc, kCGImagePropertyIPTCByline): .creator,
            .xmp("dc:creator"): .creator, prop(png, kCGImagePropertyPNGAuthor): .creator,
            prop(tiff, kCGImagePropertyTIFFCopyright): .copyright,
            prop(iptc, kCGImagePropertyIPTCCopyrightNotice): .copyright, .xmp("dc:rights"): .copyright,
            prop(png, kCGImagePropertyPNGCopyright): .copyright,
            prop(iptc, kCGImagePropertyIPTCKeywords): .keywords, .xmp("dc:subject"): .keywords,
            .dictionary(kCGImagePropertyGPSDictionary as String): .location,
            prop(exif, kCGImagePropertyExifDateTimeOriginal): .dateTaken,
            prop(iptc, kCGImagePropertyIPTCDateCreated): .dateTaken,
            .xmp("xmp:CreateDate"): .dateTaken, .xmp("photoshop:DateCreated"): .dateTaken,
            .xmp("xmp:Rating"): .rating,
        ]
        for field in MetadataOverrideField.all {
            guard case let .custom(namespace, key) = field else { continue }
            for path in MetadataOverrides.customPaths(namespace, key) where map[path] == nil { map[path] = field }
        }
        return map
    }()

    /// The editable field stored at `path`, or nil when the panel can only remove it.
    public static func editableField(for path: MetadataPath) -> MetadataOverrideField? { editableMap[path] }
}
