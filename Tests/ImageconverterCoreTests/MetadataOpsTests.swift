import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class MetadataOpsTests: XCTestCase {
    private let gps = kCGImagePropertyGPSDictionary as String
    private let iptc = kCGImagePropertyIPTCDictionary as String
    private let tiff = kCGImagePropertyTIFFDictionary as String
    private let exif = kCGImagePropertyExifDictionary as String
    private let png = kCGImagePropertyPNGDictionary as String
    private let makerApple = "{MakerApple}"

    private let iptcLocation: [CFString] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
        kCGImagePropertyIPTCContentLocationCode, kCGImagePropertyIPTCContentLocationName,
        kCGImagePropertyIPTCExtLocationShown, kCGImagePropertyIPTCExtLocationCreated
    ]
    private let tiffCamera: [CFString] = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
        kCGImagePropertyTIFFHostComputer
    ]
    private let exifCamera: [CFString] = [
        kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSpecification,
        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
        kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifMakerNote, kCGImagePropertyExifImageUniqueID
    ]
    private let wholeCameraDicts: [String] = [
        kCGImagePropertyExifAuxDictionary as String, kCGImagePropertyDNGDictionary as String,
        kCGImagePropertyCIFFDictionary as String, kCGImagePropertyRawDictionary as String,
        "{MakerApple}", "{MakerCanon}", "{MakerNikon}", "{MakerMinolta}", "{MakerFuji}", "{MakerOlympus}",
        "{MakerPentax}", "{MakerSony}"
    ]

    private func dict(_ keys: [CFString]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0 as String, "v" as Any) })
    }

    private func fixture() -> [String: Any] {
        var iptcDict = dict(iptcLocation)
        iptcDict[kCGImagePropertyIPTCKeywords as String] = ["kw"]
        var tiffDict = dict(tiffCamera)
        tiffDict[kCGImagePropertyTIFFArtist as String] = "Old Artist"
        var exifDict = dict(exifCamera)
        exifDict[kCGImagePropertyExifFNumber as String] = 1.8
        var props: [String: Any] = [
            gps: [kCGImagePropertyGPSLatitude as String: 59.3],
            iptc: iptcDict, tiff: tiffDict, exif: exifDict,
            png: [kCGImagePropertyPNGSoftware as String: "Tool", kCGImagePropertyPNGAuthor as String: "Old",
                  kCGImagePropertyPNGCopyright as String: "Old", kCGImagePropertyPNGDescription as String: "Old",
                  kCGImagePropertyPNGTitle as String: "Title"]
        ]
        for key in wholeCameraDicts { props[key] = ["x": 1] }
        return props
    }

    private func sub(_ props: [String: Any], _ key: String) -> [String: Any]? { props[key] as? [String: Any] }

    func testDisabledIsIdentity() {
        let options = MetadataOptions(isEnabled: false, removeAll: true, removeLocation: true, removeCamera: true,
                                      artist: "X")
        let out = MetadataOps.apply(options, to: fixture())
        XCTAssertEqual(NSDictionary(dictionary: out), NSDictionary(dictionary: fixture()))
    }

    func testRemoveLocation() {
        let out = MetadataOps.apply(MetadataOptions(isEnabled: true, removeLocation: true), to: fixture())
        XCTAssertNil(out[gps])
        for key in iptcLocation { XCTAssertNil(sub(out, iptc)?[key as String], key as String) }
        XCTAssertNotNil(sub(out, iptc)?[kCGImagePropertyIPTCKeywords as String])
        for key in tiffCamera { XCTAssertNotNil(sub(out, tiff)?[key as String], key as String) }
        for key in exifCamera { XCTAssertNotNil(sub(out, exif)?[key as String], key as String) }
        for key in wholeCameraDicts { XCTAssertNotNil(out[key], key) }
    }

    func testRemoveCamera() {
        let options = MetadataOptions(isEnabled: true, removeLocation: false, removeCamera: true)
        let out = MetadataOps.apply(options, to: fixture())
        for key in tiffCamera { XCTAssertNil(sub(out, tiff)?[key as String], key as String) }
        for key in exifCamera { XCTAssertNil(sub(out, exif)?[key as String], key as String) }
        for key in wholeCameraDicts { XCTAssertNil(out[key], key) }
        XCTAssertNil(sub(out, png)?[kCGImagePropertyPNGSoftware as String])
        XCTAssertNotNil(sub(out, png)?[kCGImagePropertyPNGTitle as String])
        XCTAssertNotNil(out[gps])
        for key in iptcLocation { XCTAssertNotNil(sub(out, iptc)?[key as String], key as String) }
        XCTAssertEqual(sub(out, tiff)?[kCGImagePropertyTIFFArtist as String] as? String, "Old Artist")
        XCTAssertNotNil(sub(out, exif)?[kCGImagePropertyExifFNumber as String])
    }

    func testEmptiedSubDictionaryIsDropped() {
        let input: [String: Any] = [gps: ["a": 1],
                                    iptc: [kCGImagePropertyIPTCCity as String: "X"],
                                    tiff: [kCGImagePropertyTIFFMake as String: "X"]]
        let out = MetadataOps.apply(MetadataOptions(isEnabled: true, removeLocation: true, removeCamera: true),
                                    to: input)
        XCTAssertTrue(out.isEmpty, "\(out)")
    }

    func testRemoveAllThenSet() {
        let options = MetadataOptions(isEnabled: true, removeAll: true, artist: "Me")
        let out = MetadataOps.apply(options, to: fixture())
        XCTAssertEqual(Set(out.keys), [tiff, iptc])
        XCTAssertEqual(sub(out, tiff)?.count, 1)
        XCTAssertEqual(sub(out, tiff)?[kCGImagePropertyTIFFArtist as String] as? String, "Me")
        XCTAssertEqual(sub(out, iptc)?[kCGImagePropertyIPTCByline as String] as? [String], ["Me"])
    }

    func testSetDoesNotTouchOthers() {
        let options = MetadataOptions(isEnabled: true, removeLocation: false,
                                      artist: "New", copyright: "(c)", description: "Desc")
        let out = MetadataOps.apply(options, to: fixture())
        XCTAssertEqual(sub(out, tiff)?[kCGImagePropertyTIFFArtist as String] as? String, "New")
        XCTAssertEqual(sub(out, tiff)?[kCGImagePropertyTIFFCopyright as String] as? String, "(c)")
        XCTAssertEqual(sub(out, tiff)?[kCGImagePropertyTIFFImageDescription as String] as? String, "Desc")
        XCTAssertEqual(sub(out, iptc)?[kCGImagePropertyIPTCCopyrightNotice as String] as? String, "(c)")
        XCTAssertEqual(sub(out, iptc)?[kCGImagePropertyIPTCCaptionAbstract as String] as? String, "Desc")
        XCTAssertEqual(sub(out, tiff)?[kCGImagePropertyTIFFMake as String] as? String, "v")
        XCTAssertNotNil(out[gps])
        XCTAssertNotNil(out[makerApple])
    }

    func testSetUpdatesPNGMirrorsOnlyWhenPresent() {
        let options = MetadataOptions(isEnabled: true, artist: "New", copyright: "(c)", description: "Desc")
        let out = MetadataOps.apply(options, to: fixture())
        XCTAssertEqual(sub(out, png)?[kCGImagePropertyPNGAuthor as String] as? String, "New")
        XCTAssertEqual(sub(out, png)?[kCGImagePropertyPNGCopyright as String] as? String, "(c)")
        XCTAssertEqual(sub(out, png)?[kCGImagePropertyPNGDescription as String] as? String, "Desc")
        XCTAssertEqual(sub(out, png)?[kCGImagePropertyPNGTitle as String] as? String, "Title")

        let jpegLike = MetadataOps.apply(options, to: [tiff: [kCGImagePropertyTIFFMake as String: "X"]])
        XCTAssertNil(jpegLike[png])

        let cleared = MetadataOps.apply(MetadataOptions(isEnabled: true, artist: ""), to: fixture())
        XCTAssertNil(sub(cleared, png)?[kCGImagePropertyPNGAuthor as String])
    }

    func testEmptyStringClears() {
        let options = MetadataOptions(isEnabled: true, removeLocation: false, artist: "")
        let out = MetadataOps.apply(options, to: fixture())
        XCTAssertNil(sub(out, tiff)?[kCGImagePropertyTIFFArtist as String])
        XCTAssertNil(sub(out, iptc)?[kCGImagePropertyIPTCByline as String])
    }

    func testEncoderDropsStaleColorTags() throws {
        let props: [String: Any] = [exif: [kCGImagePropertyExifColorSpace as String: 65535,
                                           kCGImagePropertyExifFNumber as String: 2.0]]
        let data = try ImageEncoder.encode(TestImages.make(width: 4, height: 4), properties: props,
                                           settings: OutputSettings(format: .jpeg))
        let out = try TestImages.properties(of: data)
        XCTAssertNil(sub(out, exif)?[kCGImagePropertyExifColorSpace as String])
    }

    func testEncoderDropsPNGColorTags() throws {
        let props: [String: Any] = [png: [kCGImagePropertyPNGGamma as String: 0.9,
                                          kCGImagePropertyPNGsRGBIntent as String: 3,
                                          kCGImagePropertyPNGChromaticities as String:
                                            [0.3127, 0.329, 0.64, 0.33, 0.3, 0.6, 0.15, 0.06],
                                          kCGImagePropertyPNGTitle as String: "Keep"]]
        let data = try ImageEncoder.encode(TestImages.make(width: 4, height: 4), properties: props,
                                           settings: OutputSettings(format: .png))
        let out = sub(try TestImages.properties(of: data), png)
        // ImageIO may write its own tags for the image's color space; ours must not survive.
        XCTAssertNotEqual(out?[kCGImagePropertyPNGGamma as String] as? Double, 0.9)
        XCTAssertNotEqual(out?[kCGImagePropertyPNGsRGBIntent as String] as? Int, 3)
        let chroma = out?[kCGImagePropertyPNGChromaticities as String] as? [Double]
        XCTAssertNotEqual(chroma?.first, 0.3127)
    }
}
