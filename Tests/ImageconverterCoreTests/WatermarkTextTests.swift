import ImageIO
import XCTest
@testable import ImageconverterCore

final class WatermarkTextTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try TestImages.tempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let exif: [String: Any] = [
        kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2024:07:15 10:20:30"],
        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFCopyright as String: "© Source",
                                                   kCGImagePropertyTIFFArtist as String: "Source Artist"]
    ]

    private func context(metadata: MetadataOptions = MetadataOptions(), properties: [String: Any]? = nil)
        -> WatermarkTextContext {
        WatermarkTextContext.make(source: URL(fileURLWithPath: "/photos/IMG_0001.HEIC"),
                                  properties: properties ?? exif, metadata: metadata, fileCreationDate: nil)
    }

    func testTokens() {
        let source = context()
        XCTAssertEqual(WatermarkText.render("{filename}", context: source), "IMG_0001")
        XCTAssertEqual(WatermarkText.render("{filename.ext}", context: source), "IMG_0001.HEIC")
        XCTAssertEqual(WatermarkText.render("{date:yyyy}", context: source), "2024")
        XCTAssertEqual(WatermarkText.render("{date}", context: source), "2024-07-15")
        XCTAssertEqual(WatermarkText.render("{year} {date:dd.MM.yy HH:mm}", context: source), "2024 15.07.24 10:20")
        // Copyright and artist from the source when the Metadata step doesn't set them.
        XCTAssertEqual(WatermarkText.render("{copyright}", context: source), "© Source")
        XCTAssertEqual(WatermarkText.render("{artist}", context: source), "Source Artist")
        // From the Metadata step when it is active and sets them.
        var step = MetadataOptions(isEnabled: true, removeLocation: false, artist: "Step Artist",
                                   copyright: "© Step")
        XCTAssertEqual(WatermarkText.render("{copyright} / {artist}", context: context(metadata: step)),
                       "© Step / Step Artist")
        step.isEnabled = false
        XCTAssertEqual(WatermarkText.render("{copyright}", context: context(metadata: step)), "© Source")
        // Unknown tokens, and date patterns outside the safe subset, stay literal.
        XCTAssertEqual(WatermarkText.render("{nope} {date:'x'} {Filename}", context: source),
                       "{nope} {date:'x'} {Filename}")
        XCTAssertEqual(WatermarkText.render("{unclosed", context: source), "{unclosed")
        XCTAssertEqual(WatermarkText.render("© {year} {artist}", context: context(properties: [:])), "©")
    }

    func testCopyrightFromIPTCAndPNG() {
        let iptc: [String: Any] = [kCGImagePropertyIPTCDictionary as String: [
            kCGImagePropertyIPTCCopyrightNotice as String: "© IPTC", kCGImagePropertyIPTCByline as String: ["By"]]]
        XCTAssertEqual(WatermarkText.render("{copyright} {artist}", context: context(properties: iptc)), "© IPTC By")
        let png: [String: Any] = [kCGImagePropertyPNGDictionary as String: [
            kCGImagePropertyPNGCopyright as String: "© PNG", kCGImagePropertyPNGAuthor as String: "Author"]]
        XCTAssertEqual(WatermarkText.render("{copyright} {artist}", context: context(properties: png)), "© PNG Author")
    }

    func testDateFallsBackToFileCreationDate() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let fallback = WatermarkTextContext.make(source: URL(fileURLWithPath: "/a.png"), properties: [:],
                                                 metadata: MetadataOptions(), fileCreationDate: created)
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(WatermarkText.render("{date}", context: fallback), local.string(from: created))
        let none = WatermarkTextContext(fileName: "a", fileNameWithExtension: "a.png")
        XCTAssertEqual(WatermarkText.render("x {date} {year}", context: none), "x")
    }

    func testOutputIsCleanedAndCapped() {
        let hostile = WatermarkTextContext(fileName: "a\u{202E}b\u{0007}c\nd", fileNameWithExtension: "",
                                           copyright: String(repeating: "x", count: 500))
        XCTAssertEqual(WatermarkText.render("{filename}", context: hostile), "abc d")
        XCTAssertEqual(WatermarkText.render("{copyright}", context: hostile).count, WatermarkText.maxLength)
        XCTAssertEqual(WatermarkText.clean("a\r\nb\u{2028}c\u{200B}"), "a b c")
    }

    func testPipelineBuildsContextOnlyWhenNeeded() throws {
        let url = try MetadataTestSupport.source(dir.appendingPathComponent("p.jpg"), properties: exif)
        let header = try XCTUnwrap(ImageLoader.header(of: url))
        let plain = Pipeline(steps: [PipelineStep(operation: .watermark(WatermarkOptions()))])
        XCTAssertNil(plain.watermarkTextContext(source: url, properties: header.properties))
        let disabled = Pipeline(steps: [PipelineStep(isEnabled: false, operation: .watermark(
            WatermarkOptions(content: .text(TextWatermark(text: "{filename}")))))])
        XCTAssertNil(disabled.watermarkTextContext(source: url, properties: header.properties))
        let tokens = Pipeline(steps: [PipelineStep(operation: .watermark(
            WatermarkOptions(content: .text(TextWatermark(text: "{copyright}")))))])
        let context = try XCTUnwrap(tokens.watermarkTextContext(source: url, properties: header.properties))
        XCTAssertEqual(context.fileName, "p")
        XCTAssertEqual(context.copyright, "© Source")
    }

    func testBatchAndPreviewDrawTheSameText() async throws {
        let source = dir.appendingPathComponent("AB.png")
        try TestImages.write(TestImages.make(width: 400, height: 300, color: CGColor(gray: 0, alpha: 1)),
                             to: source, type: .png)
        let options = WatermarkOptions(content: .text(TextWatermark(text: "{filename}")), anchor: .bottomLeft,
                                       sizePercent: 10, opacity: 1, marginPercent: 3)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .watermark(options))], output: .init(format: .png))
        let report = await BatchRunner.run(InputCollector.collect([source]), pipeline: pipeline,
                                           mode: .newFolder(dir.appendingPathComponent("out")))
        let written = try XCTUnwrap(report.written.first)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let item = try XCTUnwrap(InputCollector.collect([source]).first)
        guard case .ready(let preview) = await PreviewRenderer().render(item: item, index: 0, pipeline: pipeline) else {
            return XCTFail("preview failed")
        }
        var literal = options
        literal.content = .text(TextWatermark(text: "AB"))
        let expected = try ImageOps.watermark(TestImages.make(width: 400, height: 300, color: CGColor(gray: 0, alpha: 1)),
                                              literal, asset: nil)
        for row in stride(from: 250, to: 300, by: 4) {
            for col in stride(from: 0, to: 200, by: 3) {
                let want = TestImages.pixel(of: expected, x: col, y: row).red
                XCTAssertEqual(TestImages.pixel(of: decoded, x: col, y: row).red, want, accuracy: 2)
                XCTAssertEqual(TestImages.pixel(of: preview.after, x: col, y: row).red, want, accuracy: 2)
            }
        }
    }
}
