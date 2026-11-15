import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// Metadata-only pipelines copy the image data untouched (`LosslessMetadata`), with real files written by
/// ImageIO: the JPEG scan data stays byte-identical, removals are verified, unsupported formats re-encode.
final class LosslessMetadataTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let gps = kCGImagePropertyGPSDictionary as String
    private let tiff = kCGImagePropertyTIFFDictionary as String
    private let exif = kCGImagePropertyExifDictionary as String

    private var richProps: [String: Any] {
        [kCGImagePropertyOrientation as String: 6,
         tiff: [kCGImagePropertyTIFFMake as String: "MAKEX", kCGImagePropertyTIFFModel as String: "MODELX",
                kCGImagePropertyTIFFOrientation as String: 6],
         exif: [kCGImagePropertyExifDateTimeOriginal as String: "2020:01:02 03:04:05",
                kCGImagePropertyExifBodySerialNumber as String: "SERIALX"],
         gps: [kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
               kCGImagePropertyGPSLongitude as String: 18.1, kCGImagePropertyGPSLongitudeRef as String: "E"],
         kCGImageDestinationLossyCompressionQuality as String: 0.7]
    }

    private let richXMP: [(String, Any)] = [("dc:creator", ["AUTHORX"]), ("xmpRights:UsageTerms", "TERMSX")]

    /// A noisy 160 x 120 image (so the scan data is substantial) with EXIF, GPS, XMP and orientation 6.
    private func source(_ name: String, type: UTType = .jpeg, properties: [String: Any]? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let props = properties ?? richProps
        let meta = CGImageMetadataCreateMutable()
        let creator = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, "dc" as CFString, "creator" as CFString,
                                               .arrayOrdered, ["AUTHORX"] as CFArray)
        CGImageMetadataSetTagWithPath(meta, nil, "dc:creator" as CFString, try XCTUnwrap(creator))
        CGImageMetadataSetValueWithPath(meta, nil, "xmpRights:UsageTerms" as CFString, "TERMSX" as CFString)
        CGImageDestinationAddImageAndMetadata(dest, TestImages.noise(width: 160, height: 120), meta, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private func stripGPS() -> MetadataOptions { MetadataOptions(isEnabled: true, removeLocation: true) }

    private func run(_ url: URL, metadata: MetadataOptions, output: OutputSettings = OutputSettings(format: .jpeg),
                     steps: [PipelineStep] = []) async throws -> (WrittenFile, BatchReport) {
        let pipeline = Pipeline(steps: steps, output: output, metadata: metadata)
        let out = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        let report = await BatchRunner.run([InputItem(source: url, relativeDirectory: "")], pipeline: pipeline,
                                           mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        return (try WrittenFile(url: try XCTUnwrap(report.written.first)), report)
    }

    /// The bytes from the first start-of-scan marker to the end: the entropy-coded image data (and EOI).
    private func scanData(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            if bytes[index + 1] == 0xDA { return Data(bytes[index...]) }
            index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
        }
        XCTFail("no start of scan")
        return Data()
    }

    private func decodedPixels(_ data: Data) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    // MARK: JPEG

    func testGPSRemovalLeavesJPEGScanDataByteIdentical() async throws {
        let url = try source("photo.jpg")
        let original = try Data(contentsOf: url)
        XCTAssertTrue(PrivacyScanner.scan(url).findings.contains { $0.kind == .location })

        let (written, report) = try await run(url, metadata: stripGPS())
        XCTAssertEqual(report.notes.map(\.text), [LosslessMetadata.pixelsUntouchedNote])
        XCTAssertEqual(try scanData(written.data), try scanData(original), "scan data must be untouched")
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertFalse(PrivacyScanner.scan(written.url).findings.contains { $0.kind == .location })
        // The orientation flag is kept instead of rotating the pixels.
        XCTAssertEqual(written.props[kCGImagePropertyOrientation as String] as? Int, 6)
        XCTAssertEqual(written.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFOrientation as String] as? Int, 6)
        // What the options keep is kept.
        XCTAssertEqual(written.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFMake as String] as? String, "MAKEX")
        XCTAssertEqual(written.sub(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifDateTimeOriginal as String]
                       as? String, "2020:01:02 03:04:05")
        XCTAssertEqual(written.xmpArray("dc:creator"), ["AUTHORX"])
        XCTAssertEqual(written.xmp("xmpRights:UsageTerms"), "TERMSX")
        // Not larger than the original plus the metadata it carries (ImageIO pads its XMP packet).
        let overhead = written.data.count - (try scanData(written.data)).count
        let sourceOverhead = original.count - (try scanData(original)).count
        XCTAssertLessThanOrEqual(overhead, sourceOverhead + 4096)
        XCTAssertEqual(report.entries.first?.outputBytes, written.data.count)
        // The upright size is reported as before.
        XCTAssertEqual(report.entries.first?.outputWidth, 120)
        XCTAssertEqual(report.entries.first?.outputHeight, 160)
    }

    func testQualitySliderIsIgnoredWhenOnlyMetadataChanges() async throws {
        let url = try source("low.jpg")
        let (written, report) = try await run(url, metadata: stripGPS(),
                                              output: OutputSettings(format: .jpeg, quality: 0.2, progressive: true))
        XCTAssertEqual(report.notes.first?.text, LosslessMetadata.pixelsUntouchedNote)
        XCTAssertEqual(try scanData(written.data), try scanData(Data(contentsOf: url)))
    }

    func testRemovingCameraAndAuthorIsVerifiedAndLossless() async throws {
        let url = try source("camera.jpg")
        var options = stripGPS()
        options.removeCamera = true
        options.removeAuthor = true
        let (written, report) = try await run(url, metadata: options)
        XCTAssertEqual(report.notes.first?.text, LosslessMetadata.pixelsUntouchedNote)
        for secret in ["MAKEX", "MODELX", "SERIALX", "AUTHORX"] {
            XCTAssertFalse(written.contains(secret), secret)
        }
        XCTAssertEqual(try scanData(written.data), try scanData(Data(contentsOf: url)))
    }

    func testSetFieldsAreWrittenLosslessly() async throws {
        let url = try source("set.jpg")
        var options = MetadataOptions(isEnabled: true, removeLocation: false)
        options.location = .set(latitude: -33.86, longitude: 151.21, altitude: nil)
        options.title = "TITLEX"
        options.dateTaken = .shift(seconds: 3600)
        let (written, report) = try await run(url, metadata: options)
        XCTAssertEqual(report.notes.first?.text, LosslessMetadata.pixelsUntouchedNote)
        let location = try XCTUnwrap(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertEqual(try XCTUnwrap(location[kCGImagePropertyGPSLatitude as String] as? Double), 33.86, accuracy: 1e-4)
        XCTAssertEqual(location[kCGImagePropertyGPSLatitudeRef as String] as? String, "S")
        XCTAssertEqual(written.xmp("dc:title"), "TITLEX")
        XCTAssertEqual(written.sub(kCGImagePropertyExifDictionary)?[kCGImagePropertyExifDateTimeOriginal as String]
                       as? String, "2020:01:02 04:04:05")
        XCTAssertEqual(try scanData(written.data), try scanData(Data(contentsOf: url)))
    }

    func testRemoveXMPWritesNoPacket() async throws {
        let url = try source("xmp.jpg")
        var options = stripGPS()
        options.removeXMP = true
        let (written, _) = try await run(url, metadata: options)
        XCTAssertFalse(written.hasXMPPacket)
        XCTAssertFalse(written.contains("TERMSX"))
    }

    func testRemovedThumbnailIsGone() async throws {
        let url = try MetadataTestSupport.source(root.appendingPathComponent("thumb.jpg"),
                                                 properties: [gps: richProps[gps] as Any], thumbnail: true)
        XCTAssertTrue(try WrittenFile(url: url).hasEmbeddedThumbnail)
        var options = stripGPS()
        options.removeThumbnail = true
        let (written, report) = try await run(url, metadata: options)
        // The copy's EXIF thumbnail (IFD1) is cut off, so the copy stays lossless and carries no thumbnail.
        XCTAssertEqual(report.notes.map(\.text), [LosslessMetadata.pixelsUntouchedNote])
        XCTAssertFalse(written.hasEmbeddedThumbnail)
        XCTAssertNil(PrivacyScanner.embeddedThumbnailSize(in: written.data))
        XCTAssertEqual(try scanData(written.data), try scanData(Data(contentsOf: url)))
    }

    // MARK: Verification and fallback

    func testCheckReportsWhatACopyKept() throws {
        // The unchanged source as the "copy": its GPS is still there although the options remove it.
        let url = try source("kept.jpg")
        let data = try Data(contentsOf: url)
        let header = try XCTUnwrap(ImageLoader.header(of: url))
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), metadata: stripGPS())
        let expected = pipeline.outputProperties(from: header.properties, sourceWidth: header.width,
                                                 sourceHeight: header.height)
        let reference = try XCTUnwrap(LosslessMetadata.reference(expected, format: .jpeg))
        let check = LosslessMetadata.check(data, expected: expected, options: pipeline.metadata, reference: reference)
        XCTAssertTrue(check.left.contains { $0.hasPrefix("GPS ") }, "\(check.left)")
        XCTAssertEqual(LosslessMetadata.notRemovedNote(["GPS Latitude", "GPS Longitude", "GPS LatitudeRef", "GPS X"]),
                       "Lossless edit couldn't remove GPS Latitude, GPS Longitude, GPS LatitudeRef, …; re-encoded")
    }

    func testCheckReportsAMissingSetField() throws {
        let url = try source("missing.jpg")
        let data = try Data(contentsOf: url)
        let header = try XCTUnwrap(ImageLoader.header(of: url))
        var options = MetadataOptions(isEnabled: true, removeLocation: false)
        options.artist = "NEWARTIST"
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), metadata: options)
        let expected = pipeline.outputProperties(from: header.properties, sourceWidth: header.width,
                                                 sourceHeight: header.height)
        let reference = try XCTUnwrap(LosslessMetadata.reference(expected, format: .jpeg))
        let check = LosslessMetadata.check(data, expected: expected, options: options, reference: reference)
        XCTAssertTrue(check.missing.contains("TIFF Artist"), "\(check.missing)")
    }

    func testPNGFallsBackWithANote() async throws {
        let url = try source("photo.png", type: .png)
        let (written, report) = try await run(url, metadata: stripGPS(), output: OutputSettings(format: .png))
        XCTAssertEqual(report.notes.first?.text, LosslessMetadata.unsupportedNote)
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
        // The re-encode saves the photo upright.
        XCTAssertEqual(written.props[kCGImagePropertyOrientation as String] as? Int ?? 1, 1)
    }

    func testTIFFFallsBackWithANote() async throws {
        let url = try source("photo.tiff", type: .tiff)
        let (written, report) = try await run(url, metadata: stripGPS(), output: OutputSettings(format: .tiff))
        XCTAssertEqual(report.notes.first?.text, LosslessMetadata.unsupportedNote)
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
    }

    func testPixelStepsFormatChangesAndSizeModesReencodeWithoutANote() async throws {
        let url = try source("other.jpg")
        let resize = PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(80))))
        let cases: [(OutputSettings, [PipelineStep])] = [
            (OutputSettings(format: .jpeg), [resize]),
            (OutputSettings(format: .png), []),
            (OutputSettings(format: .jpeg, compression: .targetSize(bytes: 4000)), []),
            (OutputSettings(format: .jpeg, compression: .smart), []),
        ]
        for (output, steps) in cases {
            let (written, report) = try await run(url, metadata: stripGPS(), output: output, steps: steps)
            let notes = report.notes.map(\.text).joined()
            XCTAssertFalse(notes.contains(LosslessMetadata.pixelsUntouchedNote), "\(output) \(notes)")
            XCTAssertFalse(notes.contains("lossless"), "\(output) \(notes)")
            XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
        }
        // A disabled pixel step doesn't count.
        var off = resize
        off.isEnabled = false
        let (_, report) = try await run(url, metadata: stripGPS(), steps: [off])
        XCTAssertEqual(report.notes.first?.text, LosslessMetadata.pixelsUntouchedNote)
    }

    func testInactiveMetadataStepStillReencodes() async throws {
        let url = try source("plain.jpg")
        let (written, report) = try await run(url, metadata: MetadataOptions(isEnabled: false))
        XCTAssertEqual(report.notes, [])
        XCTAssertNotEqual(try scanData(written.data), try scanData(Data(contentsOf: url)))
    }

    // MARK: Floor, estimate, HEIC

    func testCopyOriginalWithARemovalFloorIsLossless() async throws {
        let url = try source("copy.jpg")
        let condition = ConditionalStep(conditions: [.hasGPS(true)], then: [.copyOriginal])
        let step = PipelineStep(operation: .condition(condition))
        let (written, report) = try await run(url, metadata: stripGPS(), output: OutputSettings(format: .png),
                                              steps: [step])
        XCTAssertEqual(written.url.pathExtension, "jpg")
        XCTAssertEqual(report.notes.first?.text,
                       ConditionalStep.convertedForPrivacyNote + "; " + LosslessMetadata.pixelsUntouchedNote)
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertEqual(try scanData(written.data), try scanData(Data(contentsOf: url)))
    }

    func testEstimateMatchesTheLosslessResult() async throws {
        let url = try source("estimate.jpg")
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), metadata: stripGPS())
        let preview = try SizeEstimator.render(item: InputItem(source: url, relativeDirectory: ""), pipeline: pipeline)
        let (written, _) = try await run(url, metadata: stripGPS())
        XCTAssertEqual(preview.bytes, written.data.count)
        XCTAssertEqual(preview.note, LosslessMetadata.pixelsUntouchedNote)
        XCTAssertNil(preview.quality)
        XCTAssertFalse(preview.privacy?.findings.contains { $0.kind == .location } ?? true)
        // Both views are the upright original.
        XCTAssertEqual(preview.encoded?.width, 120)
        XCTAssertEqual(preview.original?.width, 120)
    }

    func testHEICGPSRemovalKeepsImageData() async throws {
        guard OutputFormat.available().contains(.heic) else { throw XCTSkip("No HEIC encoder") }
        let url = try source("photo.heic", type: .heic)
        let (written, report) = try await run(url, metadata: stripGPS(), output: OutputSettings(format: .heic))
        XCTAssertEqual(report.notes.first?.text, LosslessMetadata.pixelsUntouchedNote)
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertFalse(PrivacyScanner.scan(written.url).findings.contains { $0.kind == .location })
        XCTAssertEqual(written.props[kCGImagePropertyOrientation as String] as? Int, 6)
        XCTAssertEqual(try decodedPixels(written.data), try decodedPixels(Data(contentsOf: url)))
    }
}
