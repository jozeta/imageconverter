import Foundation
import ImageIO

/// Where a custom metadata field is written.
public enum MetadataNamespace: String, Codable, Sendable, CaseIterable {
    case exif, iptc, xmp
}

/// One custom field the Metadata step sets. Only keys in `MetadataFields.writable` are written or
/// decoded; the value is sanitised (no control characters, at most 2000 characters). An empty value
/// is ignored (the field is left as it is); use the removal options to clear fields.
public struct MetadataField: Codable, Equatable, Hashable, Sendable {
    public var namespace: MetadataNamespace
    public var key: String
    public var value: String {
        didSet { value = MetadataFields.sanitized(value) }
    }

    public init(namespace: MetadataNamespace, key: String, value: String) {
        self.namespace = namespace
        self.key = key
        self.value = MetadataFields.sanitized(value)
    }

    private enum CodingKeys: String, CodingKey { case namespace, key, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(namespace: try container.decode(MetadataNamespace.self, forKey: .namespace),
                  key: try container.decode(String.self, forKey: .key),
                  value: try container.decodeIfPresent(String.self, forKey: .value) ?? "")
    }
}

/// The allowlist of custom fields, and the text rules shared by the Metadata step.
public enum MetadataFields {
    public static let maxValueLength = 2000
    public static let maxKeywordLength = 64
    public static let maxKeywords = 64

    /// EXIF fields by name, with the property dictionary and key they are written to.
    static let exifTargets: [String: (dictionary: CFString, key: CFString)] = [
        "ImageDescription": (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription),
        "Artist": (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist),
        "Copyright": (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright),
        "Software": (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFSoftware),
        "Make": (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake),
        "Model": (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel),
        "LensModel": (kCGImagePropertyExifDictionary, kCGImagePropertyExifLensModel),
        "UserComment": (kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment),
        "BodySerialNumber": (kCGImagePropertyExifDictionary, kCGImagePropertyExifBodySerialNumber),
    ]

    /// IPTC fields by name, with their `{IPTC}` key and whether ImageIO stores them as a list.
    static let iptcTargets: [String: (key: CFString, isList: Bool)] = [
        "ObjectName": (kCGImagePropertyIPTCObjectName, false),
        "Headline": (kCGImagePropertyIPTCHeadline, false),
        "Byline": (kCGImagePropertyIPTCByline, true),
        "BylineTitle": (kCGImagePropertyIPTCBylineTitle, true),
        "Credit": (kCGImagePropertyIPTCCredit, false),
        "Source": (kCGImagePropertyIPTCSource, false),
        "CopyrightNotice": (kCGImagePropertyIPTCCopyrightNotice, false),
        "CaptionAbstract": (kCGImagePropertyIPTCCaptionAbstract, false),
        "City": (kCGImagePropertyIPTCCity, false),
        "SubLocation": (kCGImagePropertyIPTCSubLocation, false),
        "ProvinceState": (kCGImagePropertyIPTCProvinceState, false),
        "CountryName": (kCGImagePropertyIPTCCountryPrimaryLocationName, false),
        "CountryCode": (kCGImagePropertyIPTCCountryPrimaryLocationCode, false),
        "Writer": (kCGImagePropertyIPTCWriterEditor, false),
        "SpecialInstructions": (kCGImagePropertyIPTCSpecialInstructions, false),
        "OriginalTransmissionReference": (kCGImagePropertyIPTCOriginalTransmissionReference, false),
    ]

    /// XMP paths the editor offers (prefix:name, standard namespaces ImageIO knows).
    static let xmpPaths: [String] = [
        "dc:title", "dc:creator", "dc:description", "dc:rights", "photoshop:Headline", "photoshop:City",
        "photoshop:Country", "photoshop:Credit", "photoshop:Source", "photoshop:Instructions",
        "xmpRights:UsageTerms", "xmpRights:WebStatement", "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode",
    ]

    /// The keys the editor offers per namespace, in display order.
    public static let writable: [MetadataNamespace: [String]] = [
        .exif: ["ImageDescription", "Artist", "Copyright", "Software", "Make", "Model", "LensModel", "UserComment",
                "BodySerialNumber"],
        .iptc: ["ObjectName", "Headline", "Byline", "BylineTitle", "Credit", "Source", "CopyrightNotice",
                "CaptionAbstract", "City", "SubLocation", "ProvinceState", "CountryName", "CountryCode", "Writer",
                "SpecialInstructions", "OriginalTransmissionReference"],
        .xmp: xmpPaths,
    ]

    public static func isWritable(_ namespace: MetadataNamespace, _ key: String) -> Bool {
        writable[namespace]?.contains(key) ?? false
    }

    /// `text` without control characters and Unicode noncharacters, cut to `maxValueLength` characters.
    public static func sanitized(_ text: String, limit: Int = maxValueLength) -> String {
        let scalars = text.unicodeScalars.filter { $0.properties.generalCategory != .control && isXMLSafe($0) }
        return String(String(String.UnicodeScalarView(scalars)).prefix(limit))
    }

    /// `text` without the scalars XML 1.0 forbids (C0 controls other than tab, line feed and return, and the
    /// noncharacters U+FFFE, U+FFFF, U+FDD0–U+FDEF and every plane's …FFFE/…FFFF): one of them makes the
    /// whole XMP packet unreadable.
    public static func xmlSafe(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter {
            isXMLSafe($0) && ($0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r")
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isXMLSafe(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.properties.isNoncharacterCodePoint
    }

    /// Keywords cleaned for writing: sanitised, trimmed, at most 64 characters each, empty ones dropped,
    /// repeats (ignoring case) dropped keeping the first, at most 64 in all.
    public static func normalizedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for keyword in keywords {
            let clean = String(sanitized(keyword).trimmingCharacters(in: .whitespaces).prefix(maxKeywordLength))
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            result.append(clean)
            if result.count == maxKeywords { break }
        }
        return result
    }

    /// A custom field as stored, before the allowlist check (decoding it never fails on an unknown namespace).
    struct RawField: Decodable {
        let namespace: String
        let key: String
        let value: String?
    }

    /// The decoded entries that are allowed: unknown namespaces and keys outside the allowlist are dropped.
    static func allowed(_ raw: [RawField]) -> [MetadataField] {
        raw.compactMap { field in
            guard let namespace = MetadataNamespace(rawValue: field.namespace),
                  isWritable(namespace, field.key) else { return nil }
            return MetadataField(namespace: namespace, key: field.key, value: field.value ?? "")
        }
    }
}
