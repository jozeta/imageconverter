import Foundation
import ImageIO

/// A signed GPS position: degrees (negative south and west), altitude in metres (negative below sea level).
public struct GPSPosition: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double?) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

extension MetadataInspection {
    // MARK: GPS

    /// The signed position in `gps`, nil without both coordinates.
    static func position(_ gps: [String: Any]) -> GPSPosition? {
        func number(_ key: CFString) -> Double? {
            let value = gps[key as String]
            if let number = value as? NSNumber { return number.doubleValue }
            return (value as? String).flatMap(Double.init)
        }
        guard let latitude = number(kCGImagePropertyGPSLatitude), let longitude = number(kCGImagePropertyGPSLongitude),
              latitude.isFinite, longitude.isFinite else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W"
        var altitude = number(kCGImagePropertyGPSAltitude)
        if let value = altitude, (gps[kCGImagePropertyGPSAltitudeRef as String] as? NSNumber)?.intValue == 1 {
            altitude = -value
        }
        return GPSPosition(latitude: south ? -abs(latitude) : abs(latitude),
                           longitude: west ? -abs(longitude) : abs(longitude),
                           altitude: altitude.flatMap { $0.isFinite ? $0 : nil })
    }

    /// "59.3293° N, 18.0686° E" (and ", 12 m" with an altitude).
    public static func positionText(_ position: GPSPosition) -> String {
        let latitude = String(format: "%.4f° %@", abs(position.latitude), position.latitude < 0 ? "S" : "N")
        let longitude = String(format: "%.4f° %@", abs(position.longitude), position.longitude < 0 ? "W" : "E")
        let altitude = position.altitude.map { String(format: ", %.0f m", $0) } ?? ""
        return "\(latitude), \(longitude)\(altitude)"
    }

    /// The XMP paths ImageIO keeps as twins of the property dictionaries' IPTC and TIFF fields.
    static func twinPaths(in metadata: CGImageMetadata, properties: [String: Any]) -> Set<String> {
        var paths = Set<String>()
        for dictionary in [MetadataOps.iptcKey, MetadataOps.tiffKey] {
            for key in (properties[dictionary] as? [String: Any] ?? [:]).keys {
                guard let tag = CGImageMetadataCopyTagMatchingImageProperty(metadata, dictionary as CFString, key as CFString),
                      let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag)
                else { continue }
                paths.insert("\(prefix):\(name)")
            }
        }
        return paths
    }

    // MARK: Groups

    /// XMP namespaces that only mirror the property dictionaries (shown there).
    static let mirrorNamespaces: Set<String> = Set([
        kCGImageMetadataNamespaceExif, kCGImageMetadataNamespaceExifAux, kCGImageMetadataNamespaceExifEX,
        kCGImageMetadataNamespaceTIFF, "http://ns.apple.com/ImageIO/1.0/" as CFString,
    ].map { $0 as String })

    /// Fields ImageIO writes from the image itself: shown under Technical, never removed.
    static let structural: Set<String> = [
        "Orientation", "Compression", "PhotometricInterpretation", "ResolutionUnit", "XResolution", "YResolution",
        "TileWidth", "TileLength", "PlanarConfiguration", "BitsPerSample", "SamplesPerPixel", "RowsPerStrip",
        "ColorSpace", "PixelXDimension", "PixelYDimension", "ExifVersion", "FlashPixVersion", "ComponentsConfiguration",
    ]

    private static let rightsIPTC: Set<String> = Set([
        kCGImagePropertyIPTCByline, kCGImagePropertyIPTCBylineTitle, kCGImagePropertyIPTCCopyrightNotice,
        kCGImagePropertyIPTCCredit, kCGImagePropertyIPTCSource, kCGImagePropertyIPTCRightsUsageTerms,
        kCGImagePropertyIPTCWriterEditor, kCGImagePropertyIPTCContact, kCGImagePropertyIPTCCreatorContactInfo,
    ].map { $0 as String })

    private static let exifAuxKey = kCGImagePropertyExifAuxDictionary as String
    private static let jfifKey = kCGImagePropertyJFIFDictionary as String

    static func group(dictionary: String, key: String) -> MetadataGroup {
        if structural.contains(key) { return .technical }
        switch dictionary {
        case MetadataOps.exifKey, Self.exifAuxKey: return .camera
        case MetadataOps.tiffKey: return tiffGroups[key] ?? .technical
        case MetadataOps.iptcKey:
            if rightsIPTC.contains(key) { return .rights }
            return MetadataOps.iptcLocationKeys.contains(key) ? .location : .description
        case MetadataOps.pngKey: return pngGroups[key] ?? .technical
        case Self.jfifKey: return .technical
        default: return .other
        }
    }

    private static let tiffGroups: [String: MetadataGroup] = [
        kCGImagePropertyTIFFMake as String: .camera, kCGImagePropertyTIFFModel as String: .camera,
        kCGImagePropertyTIFFSoftware as String: .camera, kCGImagePropertyTIFFHostComputer as String: .camera,
        kCGImagePropertyTIFFDateTime as String: .camera, kCGImagePropertyTIFFArtist as String: .rights,
        kCGImagePropertyTIFFCopyright as String: .rights, kCGImagePropertyTIFFImageDescription as String: .description,
    ]

    private static let pngGroups: [String: MetadataGroup] = [
        kCGImagePropertyPNGAuthor as String: .rights, kCGImagePropertyPNGCopyright as String: .rights,
        kCGImagePropertyPNGTitle as String: .description, kCGImagePropertyPNGDescription as String: .description,
        kCGImagePropertyPNGComment as String: .description,
    ]

    private static let rightsXMP: Set<String> = ["dc:creator", "dc:rights", "photoshop:Credit", "photoshop:Source",
                                                 "photoshop:AuthorsPosition", "photoshop:CaptionWriter",
                                                 "Iptc4xmpCore:CreatorContactInfo"]
    private static let locationXMP: Set<String> = ["photoshop:City", "photoshop:State", "photoshop:Country",
                                                   "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode",
                                                   "Iptc4xmpExt:LocationShown", "Iptc4xmpExt:LocationCreated"]
    private static let cameraXMP: Set<String> = ["xmp:CreateDate", "xmp:ModifyDate", "photoshop:DateCreated",
                                                 "xmp:CreatorTool"]

    static func xmpGroup(path: String, name: String) -> MetadataGroup {
        if path.hasPrefix("xmpRights:") || rightsXMP.contains(path) { return .rights }
        let lower = name.lowercased()
        if locationXMP.contains(path) || ["gps", "latitude", "longitude"].contains(where: lower.contains) {
            return .location
        }
        if cameraXMP.contains(path) || lower.contains("serialnumber") || lower.contains("lens") { return .camera }
        if path.hasPrefix("dc:") || path.hasPrefix("photoshop:") || path.hasPrefix("Iptc4xmpCore:") || path == "xmp:Rating" {
            return .description
        }
        return .other
    }
}
