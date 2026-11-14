import CoreGraphics
import ImageIO
import XCTest
@testable import ImageconverterCore

/// Removals against sources that carry an XMP packet, written and re-read in every rich format: what is
/// removed must be gone from the property dictionary, the XMP tree and the raw bytes.
final class MetadataXMPSourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let gps = kCGImagePropertyGPSDictionary as String
    private let iptc = kCGImagePropertyIPTCDictionary as String
    private let exif = kCGImagePropertyExifDictionary as String

    private var props: [String: Any] {
        [gps: [kCGImagePropertyGPSLatitude as String: 33.86, kCGImagePropertyGPSLatitudeRef as String: "S",
               kCGImagePropertyGPSMapDatum as String: "GPSDATUMX"],
         iptc: [kCGImagePropertyIPTCCity as String: "CITYX"],
         exif: [kCGImagePropertyExifBodySerialNumber as String: "BODYSERIALX"]]
    }

    private let xmp: [(String, Any)] = [
        ("exif:GPSLatitude", "33,51.6S"), ("photoshop:City", "CITYX"), ("Iptc4xmpCore:Location", "PLACEX"),
        ("drone-dji:GpsLatitude", "59.123456"), ("aux:SerialNumber", "AUXSERIALX"),
        ("exifEX:BodySerialNumber", "BODYSERIALX"), ("xmp:CreatorTool", "CREATORTOOLX"),
        ("crs:LensProfileName", "LENSPROFILEX"), ("dc:creator", ["AUTHORX"]),
        ("Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:CiEmailWork", "MAILX"), ("xmpRights:UsageTerms", "TERMSX"),
    ]

    private func source(_ format: OutputFormat, thumbnail: Bool = false, xmp: [(String, Any)]? = nil) throws -> URL {
        let (type, ext) = MetadataTestSupport.type(of: format)
        let url = root.appendingPathComponent("src-\(UUID().uuidString).\(ext)")
        return try MetadataTestSupport.source(url, type: type, properties: props, xmp: xmp ?? self.xmp,
                                              thumbnail: thumbnail)
    }

    private func assertGone(_ secrets: [String], paths: [String], in written: WrittenFile, source: WrittenFile,
                            _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for secret in secrets {
            XCTAssertTrue(source.contains(secret), "\(label): source must hold \(secret)", file: file, line: line)
            XCTAssertFalse(written.contains(secret), "\(label): \(secret)", file: file, line: line)
        }
        for path in paths {
            XCTAssertNil(written.meta.flatMap { CGImageMetadataCopyTagWithPath($0, nil, path as CFString) },
                         "\(label): \(path)", file: file, line: line)
        }
    }

    func testLocationRemovedFromXMPSources() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source(format)
            let written = try await MetadataTestSupport.convert(url, options: MetadataTestSupport.removing(.location),
                                                                format: format, root: root)
            XCTAssertNil(written.props[gps], "\(format)")
            XCTAssertNil(written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCCity as String], "\(format)")
            assertGone(["GPSDATUMX", "CITYX", "PLACEX", "59.123456"],
                       paths: ["exif:GPSLatitude", "photoshop:City", "Iptc4xmpCore:Location", "drone-dji:GpsLatitude"],
                       in: written, source: try WrittenFile(url: url), "\(format)")
            XCTAssertEqual(written.xmp("xmpRights:UsageTerms"), "TERMSX", "\(format)")
        }
    }

    func testCameraRemovedFromXMPSources() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source(format)
            let written = try await MetadataTestSupport.convert(url, options: MetadataTestSupport.removing(.camera),
                                                                format: format, root: root)
            XCTAssertNil(written.sub(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifBodySerialNumber as String])
            assertGone(["BODYSERIALX", "AUXSERIALX", "CREATORTOOLX", "LENSPROFILEX"],
                       paths: ["aux:SerialNumber", "exifEX:BodySerialNumber", "xmp:CreatorTool", "crs:LensProfileName"],
                       in: written, source: try WrittenFile(url: url), "\(format)")
            XCTAssertNotNil(written.props[gps], "\(format)")
        }
    }

    func testAuthorRemovedFromXMPSources() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source(format)
            let written = try await MetadataTestSupport.convert(url, options: MetadataTestSupport.removing(.author),
                                                                format: format, root: root)
            assertGone(["AUTHORX", "MAILX"], paths: ["dc:creator", "Iptc4xmpCore:CreatorContactInfo"],
                       in: written, source: try WrittenFile(url: url), "\(format)")
            XCTAssertEqual(written.xmp("photoshop:City"), "CITYX", "\(format)")
        }
    }

    func testRemoveThumbnail() async throws {
        let available = OutputFormat.available()
        for format: OutputFormat in [.jpeg, .heic, .tiff] where available.contains(format) {
            let url = try source(format, thumbnail: true)
            // ImageIO writes no thumbnails into TIFF; there the test only checks none appears.
            if format != .tiff {
                XCTAssertTrue(try WrittenFile(url: url).hasEmbeddedThumbnail, "\(format): source must hold a thumbnail")
            }
            var options = MetadataTestSupport.active()
            options.removeThumbnail = true
            let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            XCTAssertFalse(written.hasEmbeddedThumbnail, "\(format)")
            XCTAssertEqual(written.xmp("xmpRights:UsageTerms"), "TERMSX", "\(format)")
        }
    }

    func testKeywordsAddedAfterRemovalAreOnlyTheNewOnes() async throws {
        var removeAll = MetadataOptions(isEnabled: true, removeAll: true)
        removeAll.keywords = ["web"]
        var removeIPTC = MetadataTestSupport.active()
        removeIPTC.removeIPTC = true
        removeIPTC.keywords = ["web"]
        for format in MetadataTestSupport.richFormats {
            let url = try source(format, xmp: xmp + [("dc:subject", ["OLDKEYX"])])
            for options in [removeAll, removeIPTC] {
                let written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
                XCTAssertEqual(written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCKeywords as String]
                               as? [String], ["web"], "\(format)")
                XCTAssertEqual(written.xmpArray("dc:subject"), ["web"], "\(format)")
                XCTAssertFalse(written.contains("OLDKEYX"), "\(format)")
            }
        }
    }

    func testTextFieldsWrittenAsLanguageAlternatives() async throws {
        for format in MetadataTestSupport.richFormats {
            let url = try source(format, xmp: [("dc:title", "OLD")])
            var options = MetadataTestSupport.active()
            options.title = "TITLEX"
            options.copyright = "COPYX"
            options.custom = [MetadataField(namespace: .xmp, key: "dc:description", value: "DESCX"),
                              MetadataField(namespace: .xmp, key: "xmpRights:UsageTerms", value: "TERMS2X")]
            var written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            for value in ["TITLEX", "COPYX", "DESCX", "TERMS2X"] {
                XCTAssertTrue(written.contains("xml:lang=\"x-default\">\(value)<"), "\(format) \(value)")
            }
            XCTAssertEqual(written.xmp("dc:title"), "TITLEX", "\(format)")

            // An IPTC field set on its own reaches its XMP twin as a language alternative too.
            options = MetadataTestSupport.active()
            options.custom = [MetadataField(namespace: .iptc, key: "ObjectName", value: "OBJX")]
            written = try await MetadataTestSupport.convert(url, options: options, format: format, root: root)
            XCTAssertTrue(written.contains("xml:lang=\"x-default\">OBJX<"), "\(format)")
            XCTAssertFalse(written.contains(">OLD<"), "\(format)")
        }
    }
}
