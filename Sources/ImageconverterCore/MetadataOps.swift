import Foundation
import ImageIO

/// Strips and sets image metadata on an ImageIO property dictionary.
public enum MetadataOps {
    static let gpsKey = kCGImagePropertyGPSDictionary as String
    static let iptcKey = kCGImagePropertyIPTCDictionary as String
    static let tiffKey = kCGImagePropertyTIFFDictionary as String
    static let exifKey = kCGImagePropertyExifDictionary as String
    static let pngKey = kCGImagePropertyPNGDictionary as String
    private static let makerPrefix = "{Maker"

    static let iptcLocationKeys: [String] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
        kCGImagePropertyIPTCContentLocationCode, kCGImagePropertyIPTCContentLocationName,
        kCGImagePropertyIPTCExtLocationShown, kCGImagePropertyIPTCExtLocationCreated
    ].map { $0 as String }

    static let tiffCameraKeys: [String] = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
        kCGImagePropertyTIFFHostComputer
    ].map { $0 as String }

    static let exifCameraKeys: [String] = [
        kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSpecification,
        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
        kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifMakerNote, kCGImagePropertyExifImageUniqueID
    ].map { $0 as String }

    private static let cameraDictionaries: [String] = [CFString]([
        kCGImagePropertyExifAuxDictionary, kCGImagePropertyDNGDictionary, kCGImagePropertyCIFFDictionary,
        kCGImagePropertyRawDictionary
    ]).map { $0 as String }

    static let iptcAuthorKeys: [String] = [
        kCGImagePropertyIPTCByline, kCGImagePropertyIPTCBylineTitle, kCGImagePropertyIPTCWriterEditor,
        kCGImagePropertyIPTCContact, kCGImagePropertyIPTCCreatorContactInfo
    ].map { $0 as String }

    private struct Field {
        let tiff: CFString?
        let iptc: CFString
        let png: CFString
        var iptcAsArray = false
    }

    /// Returns `properties` with the options applied: strip (all but the kept fields, or location, camera,
    /// author, IPTC, thumbnail), then set fields (GPS, dates, text fields, keywords, custom fields).
    /// `metadata` is the source's XMP view; its keywords join the IPTC ones when keywords are added.
    public static func apply(_ options: MetadataOptions, to properties: [String: Any],
                             metadata: CGImageMetadata? = nil) -> [String: Any] {
        guard options.isActive else { return properties }
        var props: [String: Any] = options.removeAll ? kept(options.keepWhenRemovingAll, from: properties) : properties
        if !options.removeAll { strip(options, in: &props) }
        if options.removeThumbnail {
            props.removeValue(forKey: kCGImagePropertyThumbnailImages as String)
            props[kCGImageDestinationEmbedThumbnail as String] = false
        }
        if case let .set(latitude, longitude, altitude) = options.location,
           LocationEdit.isValid(latitude: latitude, longitude: longitude, altitude: altitude) {
            props[gpsKey] = gps(latitude: latitude, longitude: longitude, altitude: altitude)
        }
        MetadataDates.apply(options.dateTaken, to: &props)
        setTextFields(options, in: &props)
        if let keywords = options.keywords {
            // The source's XMP keywords only count when the removals left the keywords in place.
            let sourceKept = !options.removeAll && !options.removeIPTC
            setKeywords(keywords, mode: options.keywordsMode, extra: sourceKept ? xmpKeywords(metadata) : [],
                        in: &props)
        }
        for field in options.custom { setCustom(field, in: &props) }
        if options.removeXMP {
            props[kCGImageMetadataShouldExcludeXMP as String] = true
            // IPTC fields that only exist in XMP; PNG, HEIC and GIF would otherwise still write them.
            if let iptc = props[iptcKey] as? [String: Any] {
                store(iptc.filter { iimKeys.contains($0.key) }, at: iptcKey, in: &props)
            }
        }
        return props
    }

    private static func strip(_ options: MetadataOptions, in props: inout [String: Any]) {
        switch options.location {
        case .keep: break
        case .remove:
            props.removeValue(forKey: gpsKey)
            remove(iptcLocationKeys, from: iptcKey, in: &props)
        case .set:
            props.removeValue(forKey: gpsKey) // replaced, with nothing of the old position left
        }
        if options.removeCamera {
            remove(tiffCameraKeys, from: tiffKey, in: &props)
            remove(exifCameraKeys, from: exifKey, in: &props)
            remove([kCGImagePropertyPNGSoftware as String], from: pngKey, in: &props)
            for key in cameraDictionaries { props.removeValue(forKey: key) }
            for key in props.keys where key.hasPrefix(makerPrefix) { props.removeValue(forKey: key) }
        }
        if options.removeAuthor {
            remove([kCGImagePropertyTIFFArtist as String], from: tiffKey, in: &props)
            remove([kCGImagePropertyExifCameraOwnerName as String], from: exifKey, in: &props)
            remove(iptcAuthorKeys, from: iptcKey, in: &props)
            remove([kCGImagePropertyPNGAuthor as String], from: pngKey, in: &props)
        }
        if options.removeIPTC { props.removeValue(forKey: iptcKey) }
    }

    private static func gps(latitude: Double, longitude: Double, altitude: Double?) -> [String: Any] {
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(latitude),
            kCGImagePropertyGPSLatitudeRef as String: latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude as String: abs(longitude),
            kCGImagePropertyGPSLongitudeRef as String: longitude < 0 ? "W" : "E",
        ]
        if let altitude {
            gps[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0
        }
        return gps
    }

    private static func setTextFields(_ options: MetadataOptions, in props: inout [String: Any]) {
        if let artist = options.artist {
            set(artist, field: Field(tiff: kCGImagePropertyTIFFArtist, iptc: kCGImagePropertyIPTCByline,
                                      png: kCGImagePropertyPNGAuthor, iptcAsArray: true), in: &props)
        }
        if let copyright = options.copyright {
            set(copyright, field: Field(tiff: kCGImagePropertyTIFFCopyright, iptc: kCGImagePropertyIPTCCopyrightNotice,
                                         png: kCGImagePropertyPNGCopyright), in: &props)
        }
        if let description = options.description {
            set(description, field: Field(tiff: kCGImagePropertyTIFFImageDescription,
                                           iptc: kCGImagePropertyIPTCCaptionAbstract,
                                           png: kCGImagePropertyPNGDescription), in: &props)
        }
        if let title = options.title {
            set(title, field: Field(tiff: nil, iptc: kCGImagePropertyIPTCObjectName, png: kCGImagePropertyPNGTitle),
                in: &props)
        }
    }

    /// The keywords ImageIO reads from IPTC (a list, or one string).
    static func iptcKeywords(_ props: [String: Any]) -> [String] {
        let value = (props[iptcKey] as? [String: Any])?[kCGImagePropertyIPTCKeywords as String]
        if let list = value as? [String] { return list }
        return (value as? String).map { [$0] } ?? []
    }

    private static func xmpKeywords(_ metadata: CGImageMetadata?) -> [String] {
        guard let metadata, let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString),
              let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    private static func setKeywords(_ keywords: [String], mode: KeywordsMode, extra: [String],
                                    in props: inout [String: Any]) {
        let existing = mode == .add ? iptcKeywords(props) + extra : []
        let merged = MetadataFields.normalizedKeywords(existing + keywords)
        var iptc = props[iptcKey] as? [String: Any] ?? [:]
        iptc[kCGImagePropertyIPTCKeywords as String] = merged.isEmpty ? nil : merged
        store(iptc, at: iptcKey, in: &props)
    }

    private static func setCustom(_ field: MetadataField, in props: inout [String: Any]) {
        let value = MetadataFields.sanitized(field.value)
        switch field.namespace {
        case .exif:
            guard let target = MetadataFields.exifTargets[field.key] else { return }
            setValue(value.isEmpty ? nil : value, key: target.key as String, in: target.dictionary as String, &props)
        case .iptc:
            guard let target = MetadataFields.iptcTargets[field.key] else { return }
            let stored: Any? = value.isEmpty ? nil : (target.isList ? [value] as Any : value as Any)
            setValue(stored, key: target.key as String, in: iptcKey, &props)
        case .xmp:
            break // written to the XMP packet (see MetadataOps+XMP)
        }
    }

    private static func setValue(_ value: Any?, key: String, in dictKey: String, _ props: inout [String: Any]) {
        var dict = props[dictKey] as? [String: Any] ?? [:]
        dict[key] = value
        store(dict, at: dictKey, in: &props)
    }

    private static func remove(_ keys: [String], from dictKey: String, in props: inout [String: Any]) {
        guard var dict = props[dictKey] as? [String: Any] else { return }
        for key in keys { dict.removeValue(forKey: key) }
        store(dict, at: dictKey, in: &props)
    }

    /// Writes `dict` back, or drops the sub-dictionary when it is empty.
    static func store(_ dict: [String: Any], at key: String, in props: inout [String: Any]) {
        if dict.isEmpty { props.removeValue(forKey: key) } else { props[key] = dict }
    }

    /// Sets (or, for an empty value, clears) a TIFF and an IPTC field, and the PNG mirror when the
    /// source already has a `{PNG}` dictionary.
    private static func set(_ value: String, field: Field, in props: inout [String: Any]) {
        let value = MetadataFields.sanitized(value)
        let clear = value.isEmpty
        if let tiff = field.tiff { setValue(clear ? nil : value, key: tiff as String, in: tiffKey, &props) }
        let iptcValue: Any = field.iptcAsArray ? [value] : value
        setValue(clear ? nil : iptcValue, key: field.iptc as String, in: iptcKey, &props)
        if props[pngKey] is [String: Any] {
            setValue(clear ? nil : value, key: field.png as String, in: pngKey, &props)
        }
    }

    /// Sets the resolution to `dpi` (nil leaves `properties` alone): the generic DPI keys, the TIFF
    /// resolution (also read from Exif-style containers) and, for JPEG, the JFIF density.
    public static func setDPI(_ dpi: Double?, format: OutputFormat, in properties: [String: Any]) -> [String: Any] {
        guard let dpi, dpi.isFinite, dpi > 0 else { return properties }
        var props = properties
        props[kCGImagePropertyDPIWidth as String] = dpi
        props[kCGImagePropertyDPIHeight as String] = dpi
        var tiff = props[tiffKey] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFXResolution as String] = dpi
        tiff[kCGImagePropertyTIFFYResolution as String] = dpi
        tiff[kCGImagePropertyTIFFResolutionUnit as String] = 2 // inches
        props[tiffKey] = tiff
        if format == .jpeg {
            let jfifKey = kCGImagePropertyJFIFDictionary as String
            var jfif = props[jfifKey] as? [String: Any] ?? [:]
            // JFIF densities are 16-bit integers.
            let density = Int(min(dpi.rounded(), Double(UInt16.max)))
            jfif[kCGImagePropertyJFIFXDensity as String] = density
            jfif[kCGImagePropertyJFIFYDensity as String] = density
            jfif[kCGImagePropertyJFIFDensityUnit as String] = 1 // dots per inch
            props[jfifKey] = jfif
        }
        return props
    }
}
