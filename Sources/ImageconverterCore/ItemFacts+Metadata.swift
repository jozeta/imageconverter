import Foundation
import ImageIO

/// What reading a file's facts does beyond its header and file attributes; only what a pipeline's conditions
/// need is read.
public struct FactNeeds: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Decodes a small thumbnail to check a header's transparency claim.
    public static let alphaScan = FactNeeds(rawValue: 1 << 0)
    /// Reads the XMP packet (fields and dates that may only be there).
    public static let xmp = FactNeeds(rawValue: 1 << 1)
    /// Counts frames or pages (ImageIO may walk an animated file for it).
    public static let frames = FactNeeds(rawValue: 1 << 2)

    public static let all: FactNeeds = [.alphaScan, .xmp, .frames]
}

extension ItemFacts {
    /// The date a date condition reads.
    public func date(_ field: DateField) -> Date? {
        switch field {
        case .taken: return dateTaken
        case .created: return created
        case .modified: return modified
        }
    }

    /// The values of one metadata field (empty when it is missing).
    public func values(of subject: MetadataSubject) -> [String] {
        if case .named(.cameraMake) = subject, let make { return [make] }
        if case .named(.cameraModel) = subject, let model { return [model] }
        return metadata[subject] ?? []
    }

    /// Fills the date taken, the metadata fields and the image facts from the header and (when read) XMP.
    mutating func readMetadata(_ properties: [String: Any], xmp: CGImageMetadata?) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        dateTaken = Self.exifDate(exif[kCGImagePropertyExifDateTimeOriginal as String])
            ?? Self.xmpDate(xmp)
        bitsPerComponent = (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue
        isFloat = properties[kCGImagePropertyIsFloat as String] as? Bool ?? false
        colorModel = Self.cleaned(properties[kCGImagePropertyColorModel as String])
        profileName = Self.cleaned(properties[kCGImagePropertyProfileName as String])
        dpi = (properties[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue
            ?? (properties[kCGImagePropertyDPIHeight as String] as? NSNumber)?.doubleValue
        exifOrientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1

        var fields: [MetadataSubject: [String]] = [:]
        func add(_ subject: MetadataSubject, _ raw: Any?) {
            // The same text often sits in TIFF, IPTC and XMP: keep it once.
            let known = fields[subject] ?? []
            let found = Self.strings(raw).filter { !known.contains($0) }
            if !found.isEmpty { fields[subject] = Array((known + found).prefix(Self.maxValues)) }
        }
        add(.named(.lens), exif[kCGImagePropertyExifLensModel as String])
        add(.named(.iso), exif[kCGImagePropertyExifISOSpeedRatings as String])
        add(.named(.focalLength), exif[kCGImagePropertyExifFocalLength as String])
        add(.named(.aperture), exif[kCGImagePropertyExifFNumber as String])
        add(.named(.shutterSpeed), exif[kCGImagePropertyExifExposureTime as String])
        add(.named(.software), tiff[kCGImagePropertyTIFFSoftware as String])
        for (field, sources) in Self.textSources {
            for source in sources {
                switch source {
                case .tiff(let key): add(.named(field), tiff[key as String])
                case .iptc(let key): add(.named(field), iptc[key as String])
                case .xmp(let path): add(.named(field), Self.xmpValues(xmp, path))
                }
            }
        }
        for (name, target) in MetadataFields.exifTargets {
            let dictionary = properties[target.dictionary as String] as? [String: Any]
            add(.custom(.exif, name), dictionary?[target.key as String])
        }
        for (name, target) in MetadataFields.iptcTargets { add(.custom(.iptc, name), iptc[target.key as String]) }
        if xmp != nil {
            for path in MetadataFields.xmpPaths { add(.custom(.xmp, path), Self.xmpValues(xmp, path)) }
        }
        metadata = fields
    }

    private enum TextSource {
        case tiff(CFString), iptc(CFString), xmp(String)
    }

    /// Where each text field is read from, in order (all found values count).
    private static let textSources: [(NamedMetadataField, [TextSource])] = [
        (.artist, [.tiff(kCGImagePropertyTIFFArtist), .iptc(kCGImagePropertyIPTCByline), .xmp("dc:creator")]),
        (.copyright, [.tiff(kCGImagePropertyTIFFCopyright), .iptc(kCGImagePropertyIPTCCopyrightNotice),
                      .xmp("dc:rights")]),
        (.title, [.iptc(kCGImagePropertyIPTCObjectName), .xmp("dc:title")]),
        (.description, [.tiff(kCGImagePropertyTIFFImageDescription), .iptc(kCGImagePropertyIPTCCaptionAbstract),
                        .xmp("dc:description")]),
        (.keywords, [.iptc(kCGImagePropertyIPTCKeywords), .xmp("dc:subject")]),
    ]

    /// At most this many values per field are kept (keywords can be long lists).
    static let maxValues = 64

    /// Strings from a metadata value: text, a number, or a list of either; cleaned, at most `maxValues`.
    static func strings(_ raw: Any?) -> [String] {
        switch raw {
        case let text as String: return cleaned(text).map { [$0] } ?? []
        case let number as NSNumber:
            let value = number.doubleValue
            return value.isFinite ? [number.stringValue] : []
        case let list as [Any]: return Array(list.prefix(maxValues).flatMap { strings($0) }.prefix(maxValues))
        default: return []
        }
    }

    /// The text of an XMP property: a simple value, or the items of an array or alternative-language list.
    private static func xmpValues(_ metadata: CGImageMetadata?, _ path: String) -> [String] {
        guard let metadata, let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { return [] }
        let value = CGImageMetadataTagCopyValue(tag)
        if let text = value as? String { return [text] }
        guard let items = value as? [CGImageMetadataTag] else { return [] }
        return items.prefix(maxValues).compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    /// EXIF dates have no time zone: read as the Mac's wall clock.
    private static func exifDate(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        return exifFormatter.date(from: String(text.prefix(19)))
    }

    /// The XMP date created (`2024-05-01T10:20:30`, or a day only), its zone ignored like EXIF's.
    private static func xmpDate(_ metadata: CGImageMetadata?) -> Date? {
        guard let metadata else { return nil }
        for path in ["exif:DateTimeOriginal", "photoshop:DateCreated", "xmp:CreateDate"] {
            guard let text = CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
            else { continue }
            if text.count >= 19, let date = xmpFormatter.date(from: String(text.prefix(19))) {
                return date
            }
            if text.count >= 10, let date = dayFormatter.date(from: String(text.prefix(10))) { return date }
        }
        return nil
    }

    // Made once: a batch parses the same few formats over and over (DateFormatter is thread-safe).
    private static let exifFormatter = formatter("yyyy:MM:dd HH:mm:ss")
    private static let xmpFormatter = formatter("yyyy-MM-dd'T'HH:mm:ss")
    private static let dayFormatter = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
