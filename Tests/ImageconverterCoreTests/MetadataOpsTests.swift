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
    private let makerApple = "{MakerApple}"

    private func fixture() -> [String: Any] {
        [
            gps: [kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLongitude as String: 18.0],
            iptc: [kCGImagePropertyIPTCCity as String: "Stockholm",
                   kCGImagePropertyIPTCCountryPrimaryLocationCode as String: "SWE",
                   kCGImagePropertyIPTCKeywords as String: ["a"]],
            tiff: [kCGImagePropertyTIFFMake as String: "Apple", kCGImagePropertyTIFFModel as String: "iPhone",
                   kCGImagePropertyTIFFArtist as String: "Old Artist"],
            exif: [kCGImagePropertyExifLensModel as String: "Lens",
                   kCGImagePropertyExifFNumber as String: 1.8],
            makerApple: ["Foo": 1],
            "{MakerSony}": ["Bar": 2]
        ]
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
        XCTAssertNil(sub(out, iptc)?[kCGImagePropertyIPTCCity as String])
        XCTAssertNil(sub(out, iptc)?[kCGImagePropertyIPTCCountryPrimaryLocationCode as String])
        XCTAssertNotNil(sub(out, iptc)?[kCGImagePropertyIPTCKeywords as String])
        XCTAssertEqual(sub(out, tiff)?[kCGImagePropertyTIFFMake as String] as? String, "Apple")
    }

    func testRemoveCamera() {
        let options = MetadataOptions(isEnabled: true, removeLocation: false, removeCamera: true)
        let out = MetadataOps.apply(options, to: fixture())
        XCTAssertNil(sub(out, tiff)?[kCGImagePropertyTIFFMake as String])
        XCTAssertNil(sub(out, tiff)?[kCGImagePropertyTIFFModel as String])
        XCTAssertNil(sub(out, exif)?[kCGImagePropertyExifLensModel as String])
        XCTAssertNil(out[makerApple])
        XCTAssertNil(out["{MakerSony}"])
        XCTAssertNotNil(out[gps])
        XCTAssertEqual(sub(out, tiff)?[kCGImagePropertyTIFFArtist as String] as? String, "Old Artist")
        XCTAssertNotNil(sub(out, exif)?[kCGImagePropertyExifFNumber as String])
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
        XCTAssertEqual(sub(out, tiff)?[kCGImagePropertyTIFFMake as String] as? String, "Apple")
        XCTAssertNotNil(out[gps])
        XCTAssertNotNil(out[makerApple])
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
}
