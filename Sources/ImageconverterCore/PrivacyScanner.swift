import CoreGraphics
import Foundation
import ImageIO

/// One kind of private information found in a file.
public struct PrivacyFinding: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case location, serialNumbers, owner, editHistory, thumbnailMismatch, captureDate, device

        public var severity: PrivacySeverity {
            switch self {
            case .location, .serialNumbers, .thumbnailMismatch: return .high
            case .owner, .editHistory: return .medium
            case .captureDate, .device: return .low
            }
        }

        public var title: String {
            switch self {
            case .location: return "GPS location"
            case .serialNumbers: return "Camera or lens serial numbers"
            case .owner: return "Owner or author names"
            case .editHistory: return "Edit history and document IDs"
            case .thumbnailMismatch: return "Embedded thumbnail may show the uncropped photo"
            case .captureDate: return "Capture date and time"
            case .device: return "Camera, device or software"
            }
        }
    }

    public let kind: Kind
    /// The fields found, by name (e.g. "Body serial number"); never their values, which are private and untrusted.
    public let fields: [String]
    public var severity: PrivacySeverity { kind.severity }

    public init(kind: Kind, fields: [String]) {
        self.kind = kind
        self.fields = fields
    }
}

public enum PrivacySeverity: Int, Comparable, Sendable {
    case low, medium, high
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What `PrivacyScanner.scan` found, most severe first.
public struct PrivacyFindings: Equatable, Sendable {
    public let findings: [PrivacyFinding]

    public init(findings: [PrivacyFinding]) {
        let order = { (kind: PrivacyFinding.Kind) in PrivacyFinding.Kind.allCases.firstIndex(of: kind) ?? 0 }
        self.findings = findings.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : order($0.kind) < order($1.kind)
        }
    }

    public var isEmpty: Bool { findings.isEmpty }
    public var highestSeverity: PrivacySeverity? { findings.first?.severity }

    /// A Metadata step that removes everything behind the high and medium findings and keeps the rest; switched
    /// off when there are none. Low findings (dates, device) are left: they are rarely sensitive and often wanted.
    public var suggestedMetadataOptions: MetadataOptions { suggestion(from: MetadataOptions(removeLocation: false)) }

    /// `base` with the removals the high and medium findings need switched on (others left as they are), and the
    /// step switched on when there is anything to remove.
    public func suggestion(from base: MetadataOptions) -> MetadataOptions {
        var options = base
        let kinds = Set(findings.filter { $0.severity >= .medium }.map(\.kind))
        guard !kinds.isEmpty else { return options }
        options.isEnabled = true
        options.isIncluded = true
        if kinds.contains(.location) { options.location = .remove }
        // Serials live in EXIF, the camera's MakerNote and aux data, all of which camera removal strips.
        if kinds.contains(.serialNumbers) { options.removeCamera = true }
        if kinds.contains(.owner) { options.removeAuthor = true }
        if kinds.contains(.thumbnailMismatch) { options.removeThumbnail = true }
        // xmpMM history and document IDs only exist in XMP.
        if kinds.contains(.editHistory) { options.removeXMP = true }
        return options
    }
}

/// Looks for private information in a file from its header and metadata only. No pixels are decoded: the
/// embedded thumbnail's size comes from the EXIF IFD1 thumbnail's own header (JPEG) or the container's
/// thumbnail list (HEIC).
public enum PrivacyScanner {
    public static func scan(_ url: URL) -> PrivacyFindings {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return PrivacyFindings(findings: []) }
        return scan(source: source, head: { readHead(of: url) })
    }

    /// Scans encoded bytes (what the app would write), e.g. to show what an output keeps.
    public static func scan(data: Data) -> PrivacyFindings {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return PrivacyFindings(findings: []) }
        return scan(source: source, head: { data.prefix(headBytes) })
    }

    private static func scan(source: CGImageSource, head: () -> Data?) -> PrivacyFindings {
        guard let header = ImageHeader.read(source) else { return PrivacyFindings(findings: []) }
        let xmp = xmpTags(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        var found: [PrivacyFinding.Kind: [String]] = [:]
        func add(_ kind: PrivacyFinding.Kind, _ fields: [String]) {
            guard !fields.isEmpty else { return }
            found[kind, default: []].append(contentsOf: fields.filter { !(found[kind] ?? []).contains($0) })
        }
        let props = header.properties
        add(.location, locationFields(props, xmp: xmp))
        add(.serialNumbers, serialFields(props, xmp: xmp))
        add(.owner, ownerFields(props, xmp: xmp))
        add(.editHistory, historyFields(xmp))
        add(.captureDate, dateFields(props, xmp: xmp))
        add(.device, deviceFields(props, xmp: xmp))
        if let thumbnail = embeddedThumbnailSize(source: source, head: head),
           aspectDiffers(image: (header.width, header.height), thumbnail: thumbnail) {
            add(.thumbnailMismatch, ["Embedded thumbnail (\(thumbnail.width) × \(thumbnail.height))"])
        }
        return PrivacyFindings(findings: found.map { PrivacyFinding(kind: $0.key, fields: $0.value) })
    }

    // MARK: Fields

    /// Top-level XMP tags as "prefix:name", outside the EXIF/TIFF mirrors ImageIO adds (the dictionaries
    /// already cover those).
    private static func xmpTags(_ metadata: CGImageMetadata?) -> Set<String> {
        guard let metadata, let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [] }
        return Set(tags.compactMap { tag in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { return nil }
            return "\(prefix):\(name)"
        })
    }

    private static func dictionary(_ key: CFString, in props: [String: Any]) -> [String: Any] {
        props[key as String] as? [String: Any] ?? [:]
    }

    private static func present(_ value: Any?) -> Bool {
        switch value {
        case nil: return false
        case let text as String: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let list as [Any]: return !list.isEmpty
        case let dict as [String: Any]: return !dict.isEmpty
        default: return true
        }
    }

    /// The names of the `(key, name)` pairs present in `dict`.
    private static func names(_ pairs: [(CFString, String)], in dict: [String: Any]) -> [String] {
        pairs.filter { present(dict[$0.0 as String]) }.map(\.1)
    }

    private static func locationFields(_ props: [String: Any], xmp: Set<String>) -> [String] {
        let gps = dictionary(kCGImagePropertyGPSDictionary, in: props)
        let coordinates = [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLongitude, kCGImagePropertyGPSAltitude]
        let hasGPS = coordinates.contains { present(gps[$0 as String]) }
            || xmp.contains { $0.hasSuffix(":GPSLatitude") || $0.hasSuffix(":GPSLongitude") }
        return hasGPS ? ["GPS position"] : []
    }

    private static func serialFields(_ props: [String: Any], xmp: Set<String>) -> [String] {
        let exif = dictionary(kCGImagePropertyExifDictionary, in: props)
        let aux = dictionary(kCGImagePropertyExifAuxDictionary, in: props)
        var fields = names([(kCGImagePropertyExifBodySerialNumber, "Body serial number"),
                            (kCGImagePropertyExifLensSerialNumber, "Lens serial number"),
                            (kCGImagePropertyExifCameraOwnerName, "Camera owner name")], in: exif)
        if present(aux[kCGImagePropertyExifAuxSerialNumber as String]) { fields.append("Body serial number") }
        if present(aux[kCGImagePropertyExifAuxLensSerialNumber as String]) { fields.append("Lens serial number") }
        // MakerNote dictionaries ({MakerCanon}, {MakerNikon}, ...) where ImageIO exposes a serial.
        for (key, value) in props where key.hasPrefix("{Maker") {
            let maker = value as? [String: Any] ?? [:]
            if maker.contains(where: { $0.key.lowercased().contains("serial") && present($0.value) }) {
                fields.append("Serial number in MakerNote")
            }
        }
        // ImageIO's XMP view mirrors the EXIF serials; count XMP only when it's the sole place they are.
        // The rule camera removal uses for XMP (`MetadataOps.isCameraTag`: any tag name containing "SerialNumber"),
        // so the suggestion clears what is found.
        let xmpSerial = xmp.contains { $0.split(separator: ":").last?.lowercased().contains("serialnumber") == true }
        if fields.isEmpty, xmpSerial {
            fields.append("Serial number (XMP)")
        }
        return unique(fields)
    }

    private static func ownerFields(_ props: [String: Any], xmp: Set<String>) -> [String] {
        var fields = names([(kCGImagePropertyTIFFArtist, "Artist")],
                           in: dictionary(kCGImagePropertyTIFFDictionary, in: props))
        fields += names([(kCGImagePropertyExifCameraOwnerName, "Camera owner name")],
                        in: dictionary(kCGImagePropertyExifDictionary, in: props))
        fields += names([(kCGImagePropertyIPTCByline, "Byline"), (kCGImagePropertyIPTCWriterEditor, "Writer")],
                        in: dictionary(kCGImagePropertyIPTCDictionary, in: props))
        fields += names([(kCGImagePropertyPNGAuthor, "Author")], in: dictionary(kCGImagePropertyPNGDictionary, in: props))
        if xmp.contains("dc:creator") { fields.append("Creator (XMP)") }
        return unique(fields)
    }

    private static func historyFields(_ xmp: Set<String>) -> [String] {
        [("xmpMM:History", "Edit history"), ("xmpMM:DocumentID", "Document ID"),
         ("xmpMM:OriginalDocumentID", "Original document ID"), ("xmpMM:InstanceID", "Instance ID"),
         ("xmpMM:DerivedFrom", "Derived from"), ("xmpMM:Ingredients", "Ingredients")]
            .filter { xmp.contains($0.0) }.map(\.1)
    }

    private static func dateFields(_ props: [String: Any], xmp: Set<String>) -> [String] {
        var fields = names([(kCGImagePropertyExifDateTimeOriginal, "Date taken"),
                            (kCGImagePropertyExifDateTimeDigitized, "Date digitized")],
                           in: dictionary(kCGImagePropertyExifDictionary, in: props))
        fields += names([(kCGImagePropertyTIFFDateTime, "Date modified")],
                        in: dictionary(kCGImagePropertyTIFFDictionary, in: props))
        fields += names([(kCGImagePropertyIPTCDateCreated, "Date created (IPTC)")],
                        in: dictionary(kCGImagePropertyIPTCDictionary, in: props))
        fields += names([(kCGImagePropertyPNGCreationTime, "Creation time")],
                        in: dictionary(kCGImagePropertyPNGDictionary, in: props))
        if xmp.contains("xmp:CreateDate") || xmp.contains("photoshop:DateCreated") { fields.append("Date created (XMP)") }
        return unique(fields)
    }

    private static func deviceFields(_ props: [String: Any], xmp: Set<String>) -> [String] {
        var fields = names([(kCGImagePropertyTIFFMake, "Camera make"), (kCGImagePropertyTIFFModel, "Camera model"),
                            (kCGImagePropertyTIFFSoftware, "Software"), (kCGImagePropertyTIFFHostComputer, "Computer")],
                           in: dictionary(kCGImagePropertyTIFFDictionary, in: props))
        fields += names([(kCGImagePropertyExifLensMake, "Lens make"), (kCGImagePropertyExifLensModel, "Lens model")],
                        in: dictionary(kCGImagePropertyExifDictionary, in: props))
        fields += names([(kCGImagePropertyPNGSoftware, "Software")], in: dictionary(kCGImagePropertyPNGDictionary, in: props))
        if xmp.contains("xmp:CreatorTool") { fields.append("Software (XMP)") }
        return unique(fields)
    }

    private static func unique(_ fields: [String]) -> [String] {
        var seen = Set<String>()
        return fields.filter { seen.insert($0).inserted }
    }

    // MARK: Embedded thumbnail

    /// Aspect ratios further apart than this (relative), beyond the thumbnail's own rounding, count as different.
    static let aspectTolerance = 0.03

    /// Whether the thumbnail's aspect ratio differs from the image's by more than rounding to the thumbnail's
    /// size can explain (both are stored unrotated, so no orientation is applied).
    static func aspectDiffers(image: (width: Int, height: Int), thumbnail: (width: Int, height: Int)) -> Bool {
        guard image.width > 0, image.height > 0, thumbnail.width > 0, thumbnail.height > 0 else { return false }
        let imageAspect = Double(image.width) / Double(image.height)
        let thumbAspect = Double(thumbnail.width) / Double(thumbnail.height)
        let rounding = 1 / Double(min(thumbnail.width, thumbnail.height))
        return abs(thumbAspect - imageAspect) / imageAspect > aspectTolerance + rounding
    }

    /// The size of the thumbnail embedded in `data` (EXIF IFD1 or a container's thumbnail), nil when it has none.
    static func embeddedThumbnailSize(in data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return embeddedThumbnailSize(source: source, head: { data.prefix(headBytes) })
    }

    private static func embeddedThumbnailSize(source: CGImageSource, head: () -> Data?) -> (width: Int, height: Int)? {
        if let info = (CGImageSourceCopyProperties(source, nil) as? [String: Any])
            .flatMap({ $0[kCGImagePropertyFileContentsDictionary as String] as? [String: Any] })
            .flatMap({ ($0[kCGImagePropertyImages as String] as? [[String: Any]])?.first }),
           let size = containerThumbnailSize(imageInfo: info) {
            return size
        }
        guard CGImageSourceGetType(source) as String? == "public.jpeg", let headData = head(),
              let tiff = exifTIFF(inJPEG: headData), let thumbnail = exifThumbnail(inTIFF: tiff),
              let thumbSource = CGImageSourceCreateWithData(thumbnail as CFData, nil),
              let thumbHeader = ImageHeader.read(thumbSource) else { return nil }
        return (thumbHeader.width, thumbHeader.height)
    }

    /// The first thumbnail's size from a container's image entry (HEIC lists them with Width/Height).
    static func containerThumbnailSize(imageInfo: [String: Any]) -> (width: Int, height: Int)? {
        guard let thumb = (imageInfo[kCGImagePropertyThumbnailImages as String] as? [[String: Any]])?.first,
              let width = thumb[kCGImagePropertyWidth as String] as? Int,
              let height = thumb[kCGImagePropertyHeight as String] as? Int, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The APP segments of a JPEG come before the image data; 16 APP segments of at most 64 KB each fit here.
    private static let headBytes = 1 << 20

    private static func readHead(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: headBytes)
    }

    /// The TIFF block of the first `Exif\0\0` APP1 segment, from the markers before the image data.
    static func exifTIFF(inJPEG data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        let exifHeader: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            // Start of scan or a frame header: no more metadata segments.
            if marker == 0xDA || ((0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xCC) { return nil }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else { return nil }
            let body = (index + 4)..<(index + 2 + length)
            if marker == 0xE1, body.count > exifHeader.count, Array(bytes[body.prefix(exifHeader.count)]) == exifHeader {
                return Data(bytes[(body.lowerBound + exifHeader.count)..<body.upperBound])
            }
            index += 2 + length
        }
        return nil
    }

    /// The JPEG thumbnail IFD1 points at (JPEGInterchangeFormat/Length), bounds-checked against the block.
    static func exifThumbnail(inTIFF tiff: Data) -> Data? {
        guard let reader = TIFFReader(tiff), let ifd0 = reader.read(4, 4), let count0 = reader.read(ifd0, 2),
              let ifd1 = reader.read(ifd0 + 2 + count0 * 12, 4), ifd1 > 0, let count1 = reader.read(ifd1, 2) else {
            return nil
        }
        var offset: Int?
        var length: Int?
        for entry in 0..<min(count1, 1000) {
            let base = ifd1 + 2 + entry * 12
            guard let tag = reader.read(base, 2) else { return nil }
            if tag == 0x0201 { offset = reader.entryValue(at: base) }
            if tag == 0x0202 { length = reader.entryValue(at: base) }
        }
        guard let offset, let length, length > 0, offset > 0, offset + length <= reader.bytes.count else { return nil }
        return Data(reader.bytes[offset..<(offset + length)])
    }
}

/// Bounds-checked reads from a TIFF block in its byte order.
private struct TIFFReader {
    let bytes: [UInt8]
    let little: Bool

    /// Nil unless the block starts with a TIFF header ("II" or "MM", then 42).
    init?(_ data: Data) {
        bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        guard read(2, 2) == 42 else { return nil }
    }

    func read(_ offset: Int, _ size: Int) -> Int? {
        guard offset >= 0, size <= 4, offset + size <= bytes.count else { return nil }
        let slice = bytes[offset..<(offset + size)]
        return (little ? slice.reversed() : Array(slice)).reduce(0) { $0 << 8 | Int($1) }
    }

    /// An IFD entry's single value by its declared type: SHORT (3) or LONG (4), left-justified in the 4-byte field.
    func entryValue(at entry: Int) -> Int? {
        switch read(entry + 2, 2) {
        case 3: return read(entry + 8, 2)
        case 4: return read(entry + 8, 4)
        default: return nil
        }
    }
}
