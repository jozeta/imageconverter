import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// What the lossless metadata copy must never carry over: Photoshop previews and other APP13 resources,
/// comments and vendor segments, embedded thumbnails (none in any output, as in 1.0), extra HEIC images and
/// auxiliary data. Set values are checked by value. Other formats re-encode with the note.
final class LosslessMetadataLeakTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private typealias Bytes = JPEGSegmentsTests

    private let gpsProps: [String: Any] = [
        kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 59.3,
                                                  kCGImagePropertyGPSLatitudeRef as String: "N"],
        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "MAKEX"],
    ]

    private func run(_ url: URL, metadata: MetadataOptions, format: OutputFormat = .jpeg) async throws
        -> (WrittenFile, String) {
        let pipeline = Pipeline(output: OutputSettings(format: format), metadata: metadata)
        let out = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        let report = await BatchRunner.run([InputItem(source: url, relativeDirectory: "")], pipeline: pipeline,
                                           mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        return (try WrittenFile(url: try XCTUnwrap(report.written.first)), report.notes.map(\.text).joined(separator: " | "))
    }

    private func options(_ change: (inout MetadataOptions) -> Void) -> MetadataOptions {
        var options = MetadataOptions(isEnabled: true, removeLocation: true)
        change(&options)
        return options
    }

    /// A noisy JPEG written by ImageIO (with GPS and Make) with `segments` inserted after its APP segments.
    private func jpeg(_ name: String, inserting segments: [UInt8]) throws -> URL {
        let plain = try HeaderFixtures.jpeg(TestImages.noise(width: 160, height: 120), properties: gpsProps, xmp: nil)
        var bytes = [UInt8](plain)
        var index = 2
        while (0xE0...0xEF).contains(bytes[index + 1]) { index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])) }
        bytes.insert(contentsOf: segments, at: index)
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// An APP13 with a Photoshop thumbnail resource (0x040C: a 28-byte header, then a JPEG), an IPTC by-line
    /// and another resource; plus a comment and an APP3 block.
    private func photoshopJPEG() throws -> URL {
        let thumbnail = try HeaderFixtures.jpeg(TestImages.make(width: 80, height: 60), properties: [:], xmp: nil)
        let header = Bytes.be32(1) + Bytes.be32(80) + Bytes.be32(60) + Bytes.be32(240) + Bytes.be32(240 * 60)
            + Bytes.be32(thumbnail.count) + Bytes.be16(24) + Bytes.be16(1)
        let iptc: [UInt8] = [0x1C, 2, 80] + Bytes.be16(10) + Array("IPTCBYLINE".utf8)
        // IPTC first: ImageIO reads the IPTC block only then.
        let resources = Bytes.resource(0x0404, iptc)
            + Bytes.resource(0x040C, header + [UInt8](thumbnail) + Array("IRBTHUMBMARK".utf8))
            + Bytes.resource(0x0BB7, Array("IRBSECRET".utf8))
        return try jpeg("photoshop.jpg", inserting: Bytes.app13(resources) + Bytes.segment(0xFE, Array("COMSECRET".utf8))
                        + Bytes.segment(0xE3, Array("APP3SECRET".utf8)))
    }

    /// The bytes from the first start-of-scan marker to the end of image.
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

    // MARK: JPEG segments

    func testPhotoshopPreviewNeverSurvives() async throws {
        let url = try photoshopJPEG()
        let cases: [(String, MetadataOptions)] = [
            ("remove all", options { $0.removeAll = true }),
            ("remove thumbnail", options { $0.removeThumbnail = true }),
            ("location only", options { _ in }),
        ]
        for (name, metadata) in cases {
            let (written, note) = try await run(url, metadata: metadata)
            for secret in ["IRBTHUMBMARK", "IRBSECRET", "COMSECRET", "APP3SECRET"] {
                XCTAssertFalse(written.contains(secret), "\(name): \(secret) [\(note)]")
            }
            XCTAssertFalse(written.data.range(of: Data(Array("8BIM".utf8) + [0x04, 0x0C])) != nil, name)
            XCTAssertFalse(written.hasEmbeddedThumbnail, name)
            XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary), name)
        }
    }

    /// ImageIO writes IPTC as resource 0x0404 plus an MD5 digest (0x0425); only the IPTC itself is kept. (ImageIO
    /// reads no IPTC at all from an APP13 holding other resources, so such files fall back to the re-encode.)
    func testIPTCResourceIsKeptAndScanDataUntouched() async throws {
        var props = gpsProps
        props[kCGImagePropertyIPTCDictionary as String] = [kCGImagePropertyIPTCByline as String: ["IPTCBYLINE"]]
        let url = try MetadataTestSupport.source(root.appendingPathComponent("iptc.jpg"), properties: props)
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data(Array("8BIM".utf8) + [0x04, 0x25])))
        let (written, note) = try await run(url, metadata: options { _ in })
        XCTAssertEqual(note, LosslessMetadata.pixelsUntouchedNote)
        XCTAssertTrue(written.contains("IPTCBYLINE"), "the IPTC by-line is kept when author isn't removed")
        XCTAssertEqual(written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCByline as String] as? [String],
                       ["IPTCBYLINE"])
        XCTAssertNil(written.data.range(of: Data(Array("8BIM".utf8) + [0x04, 0x25])))
        XCTAssertEqual(try scanData(written.data), try scanData(Data(contentsOf: url)))
    }

    /// An IPTC block without a digest or dates (as other tools write it) next to an EXIF date: the copy gets the
    /// re-encode's IPTC (removals applied, dates derived from EXIF) instead of falling back.
    func testHandMadeIPTCIsReplacedByTheReencodesBlock() async throws {
        let iptc = concat([0x1C, 2, 80], Bytes.be16(8), Array("BYLINEMK".utf8),
                         [0x1C, 2, 90], Bytes.be16(8), Array("CITYMARK".utf8))
        var props = gpsProps
        props[kCGImagePropertyExifDictionary as String] = [
            kCGImagePropertyExifDateTimeOriginal as String: "2020:01:02 03:04:05"]
        let plain = try HeaderFixtures.jpeg(TestImages.noise(width: 160, height: 120), properties: props, xmp: nil)
        var bytes = [UInt8](plain)
        var index = 2
        while (0xE0...0xEF).contains(bytes[index + 1]) { index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])) }
        bytes.insert(contentsOf: Bytes.app13(Bytes.resource(0x0404, iptc)), at: index)
        let url = root.appendingPathComponent("handmade.jpg")
        try Data(bytes).write(to: url)

        let (located, note) = try await run(url, metadata: options { _ in })
        XCTAssertEqual(note, LosslessMetadata.pixelsUntouchedNote)
        XCTAssertFalse(located.contains("CITYMARK"))
        XCTAssertTrue(located.contains("BYLINEMK"))
        let fields = try XCTUnwrap(located.sub(kCGImagePropertyIPTCDictionary))
        XCTAssertEqual(fields[kCGImagePropertyIPTCDateCreated as String] as? String, "20200102")
        XCTAssertEqual(try scanData(located.data), try scanData(Data(contentsOf: url)))

        var author = MetadataOptions(isEnabled: true, removeLocation: false)
        author.removeAuthor = true
        let (anonymous, authorNote) = try await run(url, metadata: author)
        XCTAssertEqual(authorNote, LosslessMetadata.pixelsUntouchedNote)
        XCTAssertFalse(anonymous.contains("BYLINEMK"))
        XCTAssertTrue(anonymous.contains("CITYMARK"))
    }

    /// A JFIF APP0 carrying a 4 x 4 RGB thumbnail: its bytes never reach the output.
    func testJFIFThumbnailNeverSurvives() async throws {
        var bytes = [UInt8](try HeaderFixtures.jpeg(TestImages.noise(width: 160, height: 120), properties: gpsProps,
                                                     xmp: nil))
        if bytes[3] == 0xE0 { bytes.removeSubrange(2..<(4 + (Int(bytes[4]) << 8 | Int(bytes[5])))) }
        let rgb = concat(Array("JFIFTHUMBSECRET!".utf8), [UInt8](repeating: 0x80, count: 4 * 4 * 3 - 16))
        let app0 = concat(Array("JFIF".utf8), [0, 1, 2, 0], Bytes.be16(72), Bytes.be16(72), [4, 4], rgb)
        bytes.insert(contentsOf: Bytes.segment(0xE0, app0), at: 2)
        let url = root.appendingPathComponent("jfif.jpg")
        try Data(bytes).write(to: url)
        let cases: [(String, MetadataOptions)] = [
            ("no-op", MetadataOptions(isEnabled: true, removeLocation: false)), ("location", options { _ in }),
            ("remove thumbnail", options { $0.removeThumbnail = true }), ("remove all", options { $0.removeAll = true }),
        ]
        for (name, metadata) in cases {
            let (written, note) = try await run(url, metadata: metadata)
            XCTAssertFalse(written.contains("JFIFTHUMBSECRET"), "\(name) [\(note)]")
        }
    }

    // MARK: Thumbnails

    func testImageIOThumbnailIsDroppedAndTheCopyStaysLossless() async throws {
        let url = try MetadataTestSupport.source(root.appendingPathComponent("thumb.jpg"), properties: gpsProps,
                                                 thumbnail: true)
        XCTAssertTrue(try WrittenFile(url: url).hasEmbeddedThumbnail)
        for removeThumbnail in [false, true] {
            let (written, note) = try await run(url, metadata: options { $0.removeThumbnail = removeThumbnail })
            XCTAssertFalse(written.hasEmbeddedThumbnail, "removeThumbnail \(removeThumbnail) [\(note)]")
            XCTAssertEqual(note, LosslessMetadata.pixelsUntouchedNote)
            XCTAssertEqual(try scanData(written.data), try scanData(Data(contentsOf: url)))
        }
    }

    func testStaleSameAspectThumbnailNeverReachesTheOutput() async throws {
        // A solid 160 x 120 picture's thumbnail on a noise body of the same aspect: the aspect check can't see it.
        let data = try HeaderFixtures.jpegWithForeignThumbnail(
            body: TestImages.noise(width: 160, height: 120), thumbnailSource: TestImages.make(width: 160, height: 120),
            properties: gpsProps, xmp: nil)
        let url = root.appendingPathComponent("stale.jpg")
        try data.write(to: url)
        XCTAssertTrue(try WrittenFile(url: url).hasEmbeddedThumbnail)
        let cases: [MetadataOptions] = [options { _ in }, options { $0.removeCamera = true },
                                        MetadataOptions(isEnabled: true, removeLocation: false)]
        for metadata in cases {
            let (written, note) = try await run(url, metadata: metadata)
            XCTAssertFalse(written.hasEmbeddedThumbnail, note)
        }
    }

    // MARK: HEIC

    func testHEICWithAThumbnailIsReencodedWithoutOne() async throws {
        guard OutputFormat.available().contains(.heic) else { throw XCTSkip("No HEIC encoder") }
        let url = try MetadataTestSupport.source(root.appendingPathComponent("thumb.heic"), type: .heic,
                                                 properties: gpsProps, thumbnail: true)
        XCTAssertTrue(try WrittenFile(url: url).hasEmbeddedThumbnail)
        let (written, note) = try await run(url, metadata: options { _ in }, format: .heic)
        XCTAssertFalse(written.hasEmbeddedThumbnail, note)
        XCTAssertTrue(note.hasPrefix("Lossless edit couldn't remove"), note)
        XCTAssertTrue(note.contains("Embedded thumbnail"), note)
    }

    func testContainerLeftoversAreReported() throws {
        guard OutputFormat.available().contains(.heic) else { throw XCTSkip("No HEIC encoder") }
        let thumb = try MetadataTestSupport.source(root.appendingPathComponent("t.heic"), type: .heic, thumbnail: true)
        XCTAssertEqual(LosslessMetadata.containerLeftovers(try Data(contentsOf: thumb)), ["Embedded thumbnail"])
        let plain = try MetadataTestSupport.source(root.appendingPathComponent("p.heic"), type: .heic)
        XCTAssertEqual(LosslessMetadata.containerLeftovers(try Data(contentsOf: plain)), [])
        // Two images in one file.
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(dest, TestImages.make(width: 16, height: 16), nil)
        CGImageDestinationAddImage(dest, TestImages.make(width: 16, height: 16), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertEqual(LosslessMetadata.containerLeftovers(data as Data), ["Extra images"])
    }

    func testDepthDataIsReportedAndNeverCopied() async throws {
        guard OutputFormat.available().contains(.heic) else { throw XCTSkip("No HEIC encoder") }
        // A 16 x 16 Float16 disparity map ('hdis').
        let description: [CFString: Any] = [kCGImagePropertyWidth: 16, kCGImagePropertyHeight: 16,
                                            kCGImagePropertyBytesPerRow: 32, kCGImagePropertyPixelFormat: 0x6864_6973]
        let info: [CFString: Any] = [kCGImageAuxiliaryDataInfoData: Data(count: 32 * 16),
                                     kCGImageAuxiliaryDataInfoDataDescription: description]
        let url = root.appendingPathComponent("depth.heic")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, TestImages.noise(width: 64, height: 64), gpsProps as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeDisparity, info as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) != nil else {
            throw XCTSkip("ImageIO wrote no disparity data")
        }
        XCTAssertEqual(LosslessMetadata.containerLeftovers(data), ["Disparity data"])
        let (written, note) = try await run(url, metadata: options { _ in }, format: .heic)
        XCTAssertTrue(note.contains("Disparity data"), note)
        let out = try XCTUnwrap(CGImageSourceCreateWithData(written.data as CFData, nil))
        XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(out, 0, kCGImageAuxiliaryDataTypeDisparity))
    }

    // MARK: Values

    func testASetValueIsCheckedByValue() throws {
        // The source already has a title; the "copy" (the unchanged source) keeps the old one.
        let url = try MetadataTestSupport.source(root.appendingPathComponent("title.jpg"), xmp: [("dc:title", "OLDTITLE")])
        let header = try XCTUnwrap(ImageLoader.header(of: url))
        var metadata = MetadataOptions(isEnabled: true, removeLocation: false)
        metadata.title = "NEWTITLE"
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), metadata: metadata)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let expected = pipeline.outputProperties(from: header.properties, metadata: CGImageSourceCopyMetadataAtIndex(source, 0, nil),
                                                 sourceWidth: header.width, sourceHeight: header.height)
        let reference = try XCTUnwrap(LosslessMetadata.reference(expected, format: .jpeg))
        let check = LosslessMetadata.check(try Data(contentsOf: url), expected: expected, options: metadata,
                                           reference: reference)
        XCTAssertTrue(check.missing.contains("XMP dc:title"), "\(check.missing)")
    }

    // MARK: Other formats

    func testAVIFReencodesWithTheNote() async throws {
        guard OutputFormat.available().contains(.avif) else { throw XCTSkip("No AVIF encoder") }
        let url = try MetadataTestSupport.source(root.appendingPathComponent("photo.avif"),
                                                 type: try XCTUnwrap(UTType("public.avif")), properties: gpsProps)
        let (written, note) = try await run(url, metadata: options { _ in }, format: .avif)
        XCTAssertEqual(note, LosslessMetadata.unsupportedNote)
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
    }

    /// A 4 x 4 RGB Photoshop file, raw image data. ImageIO reads PSD but doesn't write it, so it can only be
    /// converted: no lossless copy and no note.
    func testPSDIsConvertedNotCopied() async throws {
        let header = concat(Array("8BPS".utf8), Bytes.be16(1), [UInt8](repeating: 0, count: 6), Bytes.be16(3),
                            Bytes.be32(4), Bytes.be32(4), Bytes.be16(8), Bytes.be16(3))
        let sections = concat(Bytes.be32(0), Bytes.be32(0), Bytes.be32(0))
        let pixels = concat(Bytes.be16(0), [UInt8](repeating: 0x80, count: 3 * 16))
        let url = root.appendingPathComponent("layers.psd")
        try Data(header + sections + pixels).write(to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.photoshop-image")
        XCTAssertFalse(LosslessMetadata.supportedTypes.contains("com.adobe.photoshop-image"))
        let (written, note) = try await run(url, metadata: options { _ in })
        XCTAssertEqual(note, "")
        XCTAssertEqual(written.url.pathExtension, "jpg")
    }
}
