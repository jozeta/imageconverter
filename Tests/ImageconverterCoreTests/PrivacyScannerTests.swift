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

    func testXMPOnlyVendorSerialIsFoundAndCleared() async throws {
        let url = dir.appendingPathComponent("drone.jpg")
        _ = try MetadataTestSupport.source(url, xmp: [("drone-dji:InternalSerialNumber", "DJI-0042")])
        let before = PrivacyScanner.scan(url)
        XCTAssertEqual(before.findings.first { $0.kind == .serialNumbers }?.fields, ["Serial number (XMP)"])
        let options = before.suggestedMetadataOptions
        XCTAssertTrue(options.removeCamera)
        XCTAssertFalse(options.removeXMP)
        let written = try await MetadataTestSupport.convert(url, options: options, root: dir)
        XCTAssertNil(PrivacyScanner.scan(written.url).findings.first { $0.kind == .serialNumbers })
    }

    func testExifThumbnailOffsetsAsShortOrLongBigEndian() {
        let thumbnail: [UInt8] = [0xFF, 0xD8, 0xAA, 0xBB, 0xFF, 0xD9]
        func tiff(type: UInt8) -> Data {
            // Header, IFD0 at 8 with no entries, IFD1 at 14 with two entries, then the thumbnail at 44.
            var bytes: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0E]
            bytes += [0x00, 0x02]
            let value: (Int) -> [UInt8] = { type == 3 ? [0, UInt8($0), 0, 0] : [0, 0, 0, UInt8($0)] }
            bytes += [0x02, 0x01, 0x00, type, 0x00, 0x00, 0x00, 0x01] + value(44)
            bytes += [0x02, 0x02, 0x00, type, 0x00, 0x00, 0x00, 0x01] + value(thumbnail.count)
            bytes += [0x00, 0x00, 0x00, 0x00]
            XCTAssertEqual(bytes.count, 44)
            return Data(bytes + thumbnail)
        }
        XCTAssertEqual(PrivacyScanner.exifThumbnail(inTIFF: tiff(type: 3)), Data(thumbnail))
        XCTAssertEqual(PrivacyScanner.exifThumbnail(inTIFF: tiff(type: 4)), Data(thumbnail))
        XCTAssertNil(PrivacyScanner.exifThumbnail(inTIFF: tiff(type: 2)), "ASCII is not an offset")
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

extension PrivacyScannerTests {
    func testScanDataMatchesScanURL() throws {
        let url = try leakyFixture()
        let fromData = PrivacyScanner.scan(data: try Data(contentsOf: url))
        XCTAssertEqual(fromData, PrivacyScanner.scan(url))
        XCTAssertTrue(PrivacyScanner.scan(data: Data("not an image".utf8)).isEmpty)
    }
}

final class PrivacyCacheTests: XCTestCase {
    func testScansOncePerFileVersion() async throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 40, height: 30), to: url, type: .png, properties: [:])
        let cache = PrivacyCache()
        _ = await cache.findings(for: url)
        _ = await cache.findings(for: url)
        let first = await cache.scanCount
        XCTAssertEqual(first, 1)
        // A rewritten file (different size) is scanned again.
        try TestImages.write(TestImages.make(width: 80, height: 60), to: url, type: .png, properties: [:])
        _ = await cache.findings(for: url)
        let second = await cache.scanCount
        XCTAssertEqual(second, 2)
        await cache.retain(only: [])
        _ = await cache.findings(for: url)
        let third = await cache.scanCount
        XCTAssertEqual(third, 3)
    }
}

final class PrivacySummaryTests: XCTestCase {
    private func found(_ kinds: PrivacyFinding.Kind...) -> PrivacyFindings {
        PrivacyFindings(findings: kinds.map { PrivacyFinding(kind: $0, fields: ["x"]) })
    }

    func testChipNamesTheMostSevereMostCommonFinding() {
        XCTAssertNil(PrivacySummary.chip([found(), found()]))
        let all = [found(.location, .captureDate), found(.location), found(.owner), found()]
        let chip = PrivacySummary.chip(all)
        XCTAssertEqual(chip?.text, "2 images share their location")
        XCTAssertEqual(chip?.severity, .high)
        XCTAssertEqual(PrivacySummary.chip([found(.location)])?.text, "1 image shares their location")
        XCTAssertEqual(PrivacySummary.chip([found(.device)])?.severity, .low)
    }

    func testMergedUnionsKindsAndSuggestionNeverWeakens() {
        let merged = PrivacySummary.merged([found(.location), found(.owner), found(.location)])
        XCTAssertEqual(Set(merged.findings.map(\.kind)), [.location, .owner])
        var existing = MetadataOptions(isEnabled: true, removeAll: true, removeLocation: true, removeCamera: true)
        existing.removeIPTC = true
        let result = merged.suggestion(from: existing)
        XCTAssertTrue(result.removeAll && result.removeCamera && result.removeIPTC && result.removeAuthor)
        XCTAssertEqual(result.location, .remove)
    }

    func testLineAndLimits() {
        XCTAssertEqual(PrivacySummary.line(found()), "None found")
        XCTAssertEqual(PrivacySummary.line(found(.captureDate, .location)), "location, date")
        XCTAssertTrue(PrivacyStatement.limits().contains { $0.name == "Image pixels" && $0.value == "250 megapixels" })
    }
}
