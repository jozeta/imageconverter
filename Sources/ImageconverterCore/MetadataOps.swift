import Foundation
import ImageIO

/// Strips and sets image metadata on an ImageIO property dictionary.
public enum MetadataOps {
    private static let gpsKey = kCGImagePropertyGPSDictionary as String
    private static let iptcKey = kCGImagePropertyIPTCDictionary as String
    private static let tiffKey = kCGImagePropertyTIFFDictionary as String
    private static let exifKey = kCGImagePropertyExifDictionary as String
    private static let exifAuxKey = kCGImagePropertyExifAuxDictionary as String
    private static let makerPrefix = "{Maker"

    private static let iptcLocationKeys: [String] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode
    ].map { $0 as String }

    private static let tiffCameraKeys: [String] = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
        kCGImagePropertyTIFFHostComputer
    ].map { $0 as String }

    private static let exifCameraKeys: [String] = [
        kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSpecification,
        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
        kCGImagePropertyExifCameraOwnerName
    ].map { $0 as String }

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
                props.removeValue(forKey: exifAuxKey)
                for key in props.keys where key.hasPrefix(makerPrefix) { props.removeValue(forKey: key) }
            }
        }

        if let artist = options.artist {
            set(artist, tiff: kCGImagePropertyTIFFArtist, iptc: kCGImagePropertyIPTCByline,
                iptcAsArray: true, in: &props)
        }
        if let copyright = options.copyright {
            set(copyright, tiff: kCGImagePropertyTIFFCopyright, iptc: kCGImagePropertyIPTCCopyrightNotice,
                iptcAsArray: false, in: &props)
        }
        if let description = options.description {
            set(description, tiff: kCGImagePropertyTIFFImageDescription, iptc: kCGImagePropertyIPTCCaptionAbstract,
                iptcAsArray: false, in: &props)
        }
        return props
    }

    private static func remove(_ keys: [String], from dictKey: String, in props: inout [String: Any]) {
        guard var dict = props[dictKey] as? [String: Any] else { return }
        for key in keys { dict.removeValue(forKey: key) }
        props[dictKey] = dict
    }

    /// Sets (or, for an empty value, clears) a TIFF and an IPTC field.
    private static func set(_ value: String, tiff: CFString, iptc: CFString, iptcAsArray: Bool,
                            in props: inout [String: Any]) {
        let clear = value.isEmpty
        var tiffDict = props[tiffKey] as? [String: Any] ?? [:]
        var iptcDict = props[iptcKey] as? [String: Any] ?? [:]
        if clear {
            tiffDict.removeValue(forKey: tiff as String)
            iptcDict.removeValue(forKey: iptc as String)
        } else {
            tiffDict[tiff as String] = value
            iptcDict[iptc as String] = iptcAsArray ? [value] : value
        }
        props[tiffKey] = tiffDict
        props[iptcKey] = iptcDict
    }
}
