import Foundation
import ImageIO

/// Strips and sets image metadata on an ImageIO property dictionary.
public enum MetadataOps {
    private static let gpsKey = kCGImagePropertyGPSDictionary as String
    private static let iptcKey = kCGImagePropertyIPTCDictionary as String
    private static let tiffKey = kCGImagePropertyTIFFDictionary as String
    private static let exifKey = kCGImagePropertyExifDictionary as String
    private static let pngKey = kCGImagePropertyPNGDictionary as String
    private static let makerPrefix = "{Maker"

    private static let iptcLocationKeys: [String] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
        kCGImagePropertyIPTCContentLocationCode, kCGImagePropertyIPTCContentLocationName,
        kCGImagePropertyIPTCExtLocationShown, kCGImagePropertyIPTCExtLocationCreated
    ].map { $0 as String }

    private static let tiffCameraKeys: [String] = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
        kCGImagePropertyTIFFHostComputer
    ].map { $0 as String }

    private static let exifCameraKeys: [String] = [
        kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSpecification,
        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
        kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifMakerNote, kCGImagePropertyExifImageUniqueID
    ].map { $0 as String }

    private static let cameraDictionaries: [String] = [CFString]([
        kCGImagePropertyExifAuxDictionary, kCGImagePropertyDNGDictionary, kCGImagePropertyCIFFDictionary,
        kCGImagePropertyRawDictionary
    ]).map { $0 as String }

    private struct Field {
        let tiff: CFString
        let iptc: CFString
        let png: CFString
        var iptcAsArray = false
    }

    /// Returns `properties` with the options applied: strip (all, location, camera), then set fields.
    public static func apply(_ options: MetadataOptions, to properties: [String: Any]) -> [String: Any] {
        guard options.isEnabled else { return properties }
        var props: [String: Any] = options.removeAll ? [:] : properties

        if !options.removeAll {
            if options.removeLocation {
                props.removeValue(forKey: gpsKey)
                remove(iptcLocationKeys, from: iptcKey, in: &props)
            }
            if options.removeCamera {
                remove(tiffCameraKeys, from: tiffKey, in: &props)
                remove(exifCameraKeys, from: exifKey, in: &props)
                remove([kCGImagePropertyPNGSoftware as String], from: pngKey, in: &props)
                for key in cameraDictionaries { props.removeValue(forKey: key) }
                for key in props.keys where key.hasPrefix(makerPrefix) { props.removeValue(forKey: key) }
            }
        }

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
        return props
    }

    private static func remove(_ keys: [String], from dictKey: String, in props: inout [String: Any]) {
        guard var dict = props[dictKey] as? [String: Any] else { return }
        for key in keys { dict.removeValue(forKey: key) }
        store(dict, at: dictKey, in: &props)
    }

    /// Writes `dict` back, or drops the sub-dictionary when it is empty.
    private static func store(_ dict: [String: Any], at key: String, in props: inout [String: Any]) {
        if dict.isEmpty { props.removeValue(forKey: key) } else { props[key] = dict }
    }

    /// Sets (or, for an empty value, clears) a TIFF and an IPTC field, and the PNG mirror when the
    /// source already has a `{PNG}` dictionary.
    private static func set(_ value: String, field: Field, in props: inout [String: Any]) {
        let (tiff, iptc, png) = (field.tiff, field.iptc, field.png)
        let clear = value.isEmpty
        var tiffDict = props[tiffKey] as? [String: Any] ?? [:]
        var iptcDict = props[iptcKey] as? [String: Any] ?? [:]
        if clear {
            tiffDict.removeValue(forKey: tiff as String)
            iptcDict.removeValue(forKey: iptc as String)
        } else {
            tiffDict[tiff as String] = value
            iptcDict[iptc as String] = field.iptcAsArray ? [value] : value
        }
        store(tiffDict, at: tiffKey, in: &props)
        store(iptcDict, at: iptcKey, in: &props)
        if var pngDict = props[pngKey] as? [String: Any] {
            if clear { pngDict.removeValue(forKey: png as String) } else { pngDict[png as String] = value }
            store(pngDict, at: pngKey, in: &props)
        }
    }
}
