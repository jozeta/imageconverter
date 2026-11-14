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

/// Metadata edits checked on written, re-read files (every format that holds EXIF, IPTC and XMP).
final class MetadataWriteTests: XCTestCase {
    private let gps = kCGImagePropertyGPSDictionary as String
    private let iptc = kCGImagePropertyIPTCDictionary as String
    private let tiff = kCGImagePropertyTIFFDictionary as String
    private let exif = kCGImagePropertyExifDictionary as String

    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func source(_ name: String, properties: [String: Any] = [:], xmp: [(String, Any)] = [],
                        thumbnail: Bool = false) throws -> URL {
        try MetadataTestSupport.source(root.appendingPathComponent(name), properties: properties, xmp: xmp,
                                       thumbnail: thumbnail)
    }

    private var richProps: [String: Any] {
        [tiff: [kCGImagePropertyTIFFArtist as String: "SECRETAUTHOR", kCGImagePropertyTIFFCopyright as String: "COPYX",
                kCGImagePropertyTIFFMake as String: "MAKEX"],
         exif: [kCGImagePropertyExifDateTimeOriginal as String: "2020:01:02 03:04:05",
                kCGImagePropertyExifLensModel as String: "LENSX", kCGImagePropertyExifCameraOwnerName as String: "SECRETOWNER"],
         iptc: [kCGImagePropertyIPTCByline as String: ["SECRETAUTHOR"], kCGImagePropertyIPTCBylineTitle as String: ["SECRETTITLE"],
                kCGImagePropertyIPTCWriterEditor as String: "SECRETWRITER", kCGImagePropertyIPTCCity as String: "CITYX",
                kCGImagePropertyIPTCCredit as String: "CREDITX", kCGImagePropertyIPTCKeywords as String: ["KEYX"],
                kCGImagePropertyIPTCContact as String: ["SECRETCONTACT"]],
         gps: [kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N"]]
    }

    private let richXMP: [(String, Any)] = [("dc:creator", ["SECRETAUTHOR"]), ("photoshop:CaptionWriter", "SECRETWRITER"),
                                            ("xmpRights:UsageTerms", "TERMSX"), ("dc:rights", "COPYX"),
                                            ("photoshop:City", "CITYX"), ("dc:subject", ["KEYX"]),
                                            ("Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:CiEmailWork", "SECRETMAIL")]

    func testSetTitleAndKeywordsAddAndReplace() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source("kw-\(format).jpg", properties: [iptc: [kCGImagePropertyIPTCKeywords as String: ["old"]]])
            var options = MetadataTestSupport.active()
            options.title = "TITLEX"
            options.keywords = ["new", "more"]
            var written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            XCTAssertEqual(written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCObjectName as String] as? String,
                           "TITLEX", "\(format)")
            XCTAssertEqual(written.xmp("dc:title"), "TITLEX", "\(format)")
            XCTAssertEqual(written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCKeywords as String] as? [String],
                           ["old", "new", "more"], "\(format)")
            XCTAssertEqual(written.xmpArray("dc:subject"), ["old", "new", "more"], "\(format)")

            options.keywordsMode = .replace
            written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            XCTAssertEqual(written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCKeywords as String] as? [String],
                           ["new", "more"], "\(format)")
            XCTAssertEqual(written.xmpArray("dc:subject"), ["new", "more"], "\(format)")
        }
    }

    func testSetGPSWritesRefs() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source("gps-\(format).jpg", properties: [gps: [kCGImagePropertyGPSLatitude as String: 10.0,
                                                                         kCGImagePropertyGPSLatitudeRef as String: "N",
                                                                         kCGImagePropertyGPSMapDatum as String: "OLDDATUM"]])
            var options = MetadataTestSupport.active()
            options.location = .set(latitude: -33.86, longitude: 151.21, altitude: -5)
            let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            let out = try XCTUnwrap(written.sub(kCGImagePropertyGPSDictionary), "\(format)")
            XCTAssertEqual(try XCTUnwrap(out[kCGImagePropertyGPSLatitude as String] as? Double), 33.86, accuracy: 1e-4)
            XCTAssertEqual(out[kCGImagePropertyGPSLatitudeRef as String] as? String, "S", "\(format)")
            XCTAssertEqual(try XCTUnwrap(out[kCGImagePropertyGPSLongitude as String] as? Double), 151.21, accuracy: 1e-4)
            XCTAssertEqual(out[kCGImagePropertyGPSLongitudeRef as String] as? String, "E", "\(format)")
            XCTAssertEqual(try XCTUnwrap(out[kCGImagePropertyGPSAltitude as String] as? Double), 5, accuracy: 1e-4)
            XCTAssertEqual(out[kCGImagePropertyGPSAltitudeRef as String] as? Int, 1, "\(format)")
            XCTAssertFalse(written.contains("OLDDATUM"), "\(format)")
            XCTAssertNotNil(written.xmp("exif:GPSLatitude"), "\(format)")
        }
    }

    func testRemoveAuthorEverywhere() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source("author-\(format).jpg", properties: richProps, xmp: richXMP)
            var options = MetadataTestSupport.active()
            options.removeAuthor = true
            let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            for secret in ["SECRETAUTHOR", "SECRETWRITER", "SECRETTITLE", "SECRETOWNER", "SECRETCONTACT", "SECRETMAIL"] {
                XCTAssertTrue(try WrittenFile(url: url).contains(secret), "source must hold \(secret)")
                XCTAssertFalse(written.contains(secret), "\(format) \(secret)")
            }
            XCTAssertNil(written.sub(kCGImagePropertyPNGDictionary)?[kCGImagePropertyPNGAuthor as String])
            XCTAssertEqual(written.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFCopyright as String] as? String,
                           "COPYX", "\(format)")
            XCTAssertEqual(written.xmp("xmpRights:UsageTerms"), "TERMSX", "\(format)")
        }
    }

    func testRemoveIPTCOnly() async throws {
        for format in MetadataTestSupport.richFormats {
            var props = richProps
            props.removeValue(forKey: tiff) // ImageIO mirrors the TIFF artist into IPTC; leave it out here.
            let url = try source("iptc-\(format).jpg", properties: props, xmp: richXMP)
            var options = MetadataTestSupport.active()
            options.removeIPTC = true
            let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            for secret in ["CITYX", "CREDITX", "KEYX", "SECRETWRITER"] {
                XCTAssertFalse(written.contains(secret), "\(format) \(secret)")
            }
            XCTAssertNil(written.xmp("photoshop:City"), "\(format)")
            XCTAssertNotNil(written.sub(kCGImagePropertyGPSDictionary), "\(format)")
            XCTAssertEqual(written.sub(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifLensModel as String] as? String,
                           "LENSX", "\(format)")
        }
    }

    func testRemoveXMPOnly() async throws {
        let url = try source("xmp.jpg", properties: richProps, xmp: richXMP)
        XCTAssertTrue(try WrittenFile(url: url).hasXMPPacket)
        var options = MetadataTestSupport.active()
        options.removeXMP = true
        options.title = "TITLEX"
        for format: OutputFormat in [.jpeg, .tiff] {
            let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            XCTAssertFalse(written.hasXMPPacket, "\(format)")
            XCTAssertFalse(written.contains("TERMSX"), "\(format)")
            let iptcOut = written.sub(kCGImagePropertyIPTCDictionary)
            XCTAssertEqual(iptcOut?[kCGImagePropertyIPTCObjectName as String] as? String, "TITLEX", "\(format)")
            XCTAssertEqual(iptcOut?[kCGImagePropertyIPTCKeywords as String] as? [String], ["KEYX"], "\(format)")
            XCTAssertEqual(written.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFArtist as String] as? String,
                           "SECRETAUTHOR", "\(format)")
        }
        // Formats that keep EXIF and IPTC inside XMP still drop the XMP-only fields.
        for format in MetadataTestSupport.richFormats where format != .jpeg && format != .tiff {
            let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            XCTAssertFalse(written.contains("TERMSX"), "\(format)")
        }
    }

    func testRemoveAllAlsoClearsXMP() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source("all-\(format).jpg", properties: richProps, xmp: richXMP)
            let options = MetadataOptions(isEnabled: true, removeAll: true)
            let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            for secret in ["SECRETAUTHOR", "TERMSX", "COPYX", "CITYX", "KEYX", "MAKEX", "LENSX", "2020:01:02"] {
                XCTAssertFalse(written.contains(secret), "\(format) \(secret)")
            }
            XCTAssertNil(written.xmp("xmpRights:UsageTerms"), "\(format)")
            XCTAssertNil(written.xmp("dc:creator"), "\(format)")
            XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary), "\(format)")
        }
    }

    func testRemoveAllKeepsCopyrightAndDate() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source("keep-\(format).jpg", properties: richProps, xmp: richXMP)
            var options = MetadataOptions(isEnabled: true, removeAll: true)
            options.keepWhenRemovingAll = [.copyright, .dateTaken]
            let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            XCTAssertEqual(written.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFCopyright as String] as? String,
                           "COPYX", "\(format)")
            XCTAssertEqual(written.xmp("dc:rights"), "COPYX", "\(format)")
            XCTAssertEqual(written.xmp("xmpRights:UsageTerms"), "TERMSX", "\(format)")
            XCTAssertEqual(written.sub(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifDateTimeOriginal as String]
                           as? String, "2020:01:02 03:04:05", "\(format)")
            for secret in ["SECRETAUTHOR", "CITYX", "KEYX", "MAKEX", "LENSX", "CREDITX"] {
                XCTAssertFalse(written.contains(secret), "\(format) \(secret)")
            }
            XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary), "\(format)")
        }
    }

    func testRemoveAllKeepsAuthorCameraAndLocation() async throws {
        let url = try source("keep2.jpg", properties: richProps, xmp: richXMP)
        var options = MetadataOptions(isEnabled: true, removeAll: true)
        options.keepWhenRemovingAll = [.author, .cameraInfo, .location]
        let written = try await MetadataTestSupport.convert(url, options: options, root: root)
        XCTAssertEqual(written.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFArtist as String] as? String,
                       "SECRETAUTHOR")
        XCTAssertEqual(written.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFMake as String] as? String, "MAKEX")
        XCTAssertEqual(written.sub(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifLensModel as String] as? String,
                       "LENSX")
        XCTAssertNotNil(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertEqual(written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCCity as String] as? String, "CITYX")
        for secret in ["COPYX", "TERMSX", "KEYX", "CREDITX", "2020:01:02"] {
            XCTAssertFalse(written.contains(secret), secret)
        }
    }

    func testXMPPathKeepsQualityAndDPI() async throws {
        let url = try source("q.jpg", properties: richProps, xmp: richXMP)
        var pipeline = Pipeline(output: OutputSettings(format: .jpeg))
        pipeline.metadata = MetadataTestSupport.active()
        pipeline.metadata.custom = [MetadataField(namespace: .xmp, key: "dc:title", value: "T")]
        let props = pipeline.outputProperties(from: try TestImages.properties(of: Data(contentsOf: url)),
                                              metadata: nil, sourceWidth: 40, sourceHeight: 20)
        let noisy = TestImages.noise(width: 64, height: 64)
        let low = try ImageEncoder.encode(noisy, properties: props, settings: OutputSettings(format: .jpeg, quality: 0.1))
        let high = try ImageEncoder.encode(noisy, properties: props, settings: OutputSettings(format: .jpeg, quality: 1))
        XCTAssertLessThan(low.count, high.count)
        XCTAssertNotNil(try WrittenFile.decode(low).xmp("dc:title"))
        let dpi = MetadataOps.setDPI(300, format: .jpeg, in: props)
        let out = try TestImages.properties(of: ImageEncoder.encode(noisy, properties: dpi,
                                                                    settings: OutputSettings(format: .jpeg)))
        XCTAssertEqual(out[kCGImagePropertyDPIWidth as String] as? Int, 300)
        XCTAssertEqual((out[exif] as? [String: Any])?[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2020:01:02 03:04:05")
    }
}
