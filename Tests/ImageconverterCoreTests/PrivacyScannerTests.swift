import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ImageconverterCore
import XCTest

final class PrivacyScannerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private static let xmpMM = "http://ns.adobe.com/xap/1.0/mm/"

    private static var leakyProperties: [String: Any] {
        [
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 59.33, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 18.07, kCGImagePropertyGPSLongitudeRef as String: "E",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifBodySerialNumber as String: "SN-1234567",
                kCGImagePropertyExifLensSerialNumber as String: "LENS-42",
                kCGImagePropertyExifCameraOwnerName as String: "Jane Doe",
                kCGImagePropertyExifDateTimeOriginal as String: "2026:11:01 10:00:00",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFArtist as String: "Jane Doe",
                kCGImagePropertyTIFFMake as String: "Acme",
                kCGImagePropertyTIFFModel as String: "Snapper 9",
            ],
        ]
    }

    private static func historyXMP() -> CGMutableImageMetadata {
        let meta = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(meta, xmpMM as CFString, "xmpMM" as CFString, nil)
        CGImageMetadataSetValueWithPath(meta, nil, "xmpMM:DocumentID" as CFString,
                                        "xmp.did:0123456789abcdef" as CFString)
        CGImageMetadataSetValueWithPath(meta, nil, "xmpMM:OriginalDocumentID" as CFString,
                                        "xmp.did:fedcba9876543210" as CFString)
        if let tag = CGImageMetadataTagCreate(xmpMM as CFString, "xmpMM" as CFString, "History" as CFString,
                                              .arrayOrdered, ["saved", "cropped"] as CFArray) {
            CGImageMetadataSetTagWithPath(meta, nil, "xmpMM:History" as CFString, tag)
        }
        return meta
    }

    /// A 400 × 300 JPEG with GPS, serials, owner, history and the 4:1 thumbnail of an uncropped original.
    private func leakyFixture() throws -> URL {
        let data = try HeaderFixtures.jpegWithForeignThumbnail(
            body: TestImages.make(width: 400, height: 300), thumbnailSource: TestImages.make(width: 400, height: 100),
            properties: Self.leakyProperties, xmp: Self.historyXMP())
        let url = dir.appendingPathComponent("leaky.jpg")
        try data.write(to: url)
        return url
    }

    func testScannerFindsGPSSerialOwnerHistoryThumbnail() throws {
        let findings = PrivacyScanner.scan(try leakyFixture())
        let kinds = Dictionary(uniqueKeysWithValues: findings.findings.map { ($0.kind, $0) })
        XCTAssertEqual(kinds[.location]?.severity, .high)
        XCTAssertEqual(kinds[.serialNumbers]?.severity, .high)
        XCTAssertEqual(kinds[.owner]?.severity, .medium)
        XCTAssertEqual(kinds[.editHistory]?.severity, .medium)
        XCTAssertEqual(kinds[.thumbnailMismatch]?.severity, .high)
        XCTAssertEqual(kinds[.captureDate]?.severity, .low)
        XCTAssertEqual(kinds[.device]?.severity, .low)
        XCTAssertEqual(Set(kinds[.serialNumbers]?.fields ?? []), ["Body serial number", "Lens serial number",
                                                                   "Camera owner name"])
        XCTAssertTrue(kinds[.owner]?.fields.contains("Artist") ?? false)
        XCTAssertEqual(Set(kinds[.editHistory]?.fields ?? []), ["Edit history", "Document ID", "Original document ID"])
        XCTAssertEqual(findings.highestSeverity, .high)
        // Findings name fields, never their (untrusted, private) values.
        XCTAssertFalse(findings.findings.contains { $0.fields.joined().contains("SN-1234567") })
        // Sorted most severe first.
        XCTAssertEqual(findings.findings.map(\.severity), findings.findings.map(\.severity).sorted(by: >))
    }

    func testScannerFindsOwnerInPNGXMP() throws {
        let url = dir.appendingPathComponent("history.png")
        _ = try MetadataTestSupport.source(url, type: .png, xmp: [("dc:creator", ["Jane"])])
        let findings = PrivacyScanner.scan(url)
        // ImageIO mirrors dc:creator into the IPTC and PNG dictionaries too; the XMP tag itself is named.
        let owner = findings.findings.first { $0.kind == .owner }
        XCTAssertEqual(owner?.severity, .medium)
        XCTAssertTrue(owner?.fields.contains("Creator (XMP)") ?? false, "\(String(describing: owner))")
    }

    func testScannerCleanImageNoFindings() throws {
        for (type, name) in [(UTType.jpeg, "clean.jpg"), (.png, "clean.png"), (.heic, "clean.heic")] {
            let url = dir.appendingPathComponent(name)
            // An embedded thumbnail of the same picture is fine.
            try TestImages.write(TestImages.make(width: 300, height: 200), to: url, type: type,
                                 properties: [kCGImageDestinationEmbedThumbnail as String: true])
            XCTAssertEqual(PrivacyScanner.scan(url).findings, [], name)
        }
        XCTAssertTrue(PrivacyScanner.scan(dir.appendingPathComponent("missing.jpg")).findings.isEmpty)
    }

    func testHEICThumbnailMismatchFromContainer() {
        // The container lists the thumbnail's size; compare it like the EXIF one.
        let info: [String: Any] = [
            kCGImagePropertyWidth as String: 400, kCGImagePropertyHeight as String: 300,
            kCGImagePropertyThumbnailImages as String: [[kCGImagePropertyWidth as String: 320,
                                                          kCGImagePropertyHeight as String: 80]],
        ]
        XCTAssertEqual(PrivacyScanner.containerThumbnailSize(imageInfo: info)?.width, 320)
        XCTAssertTrue(PrivacyScanner.aspectDiffers(image: (400, 300), thumbnail: (320, 80)))
        XCTAssertFalse(PrivacyScanner.aspectDiffers(image: (400, 300), thumbnail: (160, 120)))
        XCTAssertFalse(PrivacyScanner.aspectDiffers(image: (4000, 3001), thumbnail: (160, 120)))
    }

    func testSuggestedOptionsClearFindings() async throws {
        let source = try leakyFixture()
        let before = PrivacyScanner.scan(source)
        let options = before.suggestedMetadataOptions
        XCTAssertTrue(options.isActive)
        XCTAssertEqual(options.location, .remove)
        XCTAssertTrue(options.removeCamera)
        XCTAssertTrue(options.removeAuthor)
        XCTAssertTrue(options.removeThumbnail)
        XCTAssertTrue(options.removeXMP)
        XCTAssertFalse(options.removeAll)

        let written = try await MetadataTestSupport.convert(source, options: options, root: dir)
        let after = PrivacyScanner.scan(written.url)
        XCTAssertEqual(after.findings.filter { $0.severity >= .medium }, [], "\(after.findings)")
        XCTAssertTrue(after.suggestedMetadataOptions == PrivacyFindings(findings: []).suggestedMetadataOptions)
    }

    func testSuggestionOnlyRemovesWhatWasFound() {
        let gpsOnly = PrivacyFindings(findings: [PrivacyFinding(kind: .location, fields: ["GPS position"])])
        let options = gpsOnly.suggestedMetadataOptions
        XCTAssertEqual(options.location, .remove)
        XCTAssertFalse(options.removeCamera || options.removeAuthor || options.removeThumbnail || options.removeXMP)
        // Low findings alone suggest nothing.
        let low = PrivacyFindings(findings: [PrivacyFinding(kind: .captureDate, fields: ["Date taken"])])
        XCTAssertEqual(low.suggestedMetadataOptions.location, .keep)
        XCTAssertFalse(low.suggestedMetadataOptions.isEnabled)
    }

    func testMalformedExifIsIgnored() {
        // Truncated or lying offsets must never crash or read out of bounds.
        let tiffHeader: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        XCTAssertNil(PrivacyScanner.exifThumbnail(inTIFF: Data(tiffHeader)))
        XCTAssertNil(PrivacyScanner.exifThumbnail(inTIFF: Data(tiffHeader + [0xFF, 0xFF])))
        XCTAssertNil(PrivacyScanner.exifThumbnail(inTIFF: Data([0x49, 0x49, 0x2A, 0x00, 0xFF, 0xFF, 0xFF, 0x7F])))
        XCTAssertNil(PrivacyScanner.exifTIFF(inJPEG: Data([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 0x45])))
        XCTAssertNil(PrivacyScanner.exifTIFF(inJPEG: Data([0xFF, 0xD8])))
    }
}
