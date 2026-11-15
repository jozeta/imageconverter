import CoreGraphics
import CoreText
import XCTest
@testable import ImageconverterCore

final class RedactPipelineTests: XCTestCase {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
    private let fill = RedactOptions(target: .both, style: .fill, fillColor: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
                                     padding: 0)

    private func pipeline(_ steps: [ImageOperation]) -> Pipeline {
        Pipeline(steps: steps.map { PipelineStep(operation: $0) })
    }

    private func isGreen(_ pixel: TestImages.Pixel) -> Bool {
        pixel.green > 250 && pixel.red < 5 && pixel.blue < 5
    }

    func testBoxesLandOnTheStepsInputAfterARotation() throws {
        // 400 × 200, red left, blue right; turned 90° clockwise it is 200 × 400 with red on top.
        let image = TestImages.twoColor(width: 400, height: 200, left: red, right: blue)
        let detector = FakeVisionDetector(faces: [CGRect(x: 0, y: 0, width: 1, height: 0.25)])
        var notes: [String] = []
        let out = try pipeline([.rotateFlip(RotateFlipOptions(rotation: .cw90)), .redact(fill)])
            .apply(to: image, focus: FocusContext(detector: detector), notes: &notes)
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 400)
        XCTAssertTrue(isGreen(TestImages.pixel(of: out, x: 100, y: 50)), "top quarter filled")
        XCTAssertEqual(TestImages.pixel(of: out, x: 100, y: 150).red, 255, accuracy: 2, "red below the box")
        XCTAssertEqual(TestImages.pixel(of: out, x: 100, y: 350).blue, 255, accuracy: 2)
        XCTAssertEqual(notes, ["Redacted 1 face"])
        // Detection saw the rotated image (portrait), not the source.
        XCTAssertTrue(detector.recorded.allSatisfy { $0.width == 200 && $0.height == 400 })
    }

    func testBoxesLandOnTheStepsInputAfterACropAndResize() throws {
        let image = TestImages.twoColor(width: 400, height: 200, left: red, right: blue)
        // Keep the right half (blue), shrink it to 100 × 100, then fill its left half.
        let detector = FakeVisionDetector(text: [CGRect(x: 0, y: 0, width: 0.5, height: 1)])
        var notes: [String] = []
        let out = try pipeline([.crop(CropOptions(mode: .aspect(width: 1, height: 1), anchor: .right)),
                                .resize(ResizeOptions(mode: .maxWidth(100))), .redact(fill)])
            .apply(to: image, focus: FocusContext(detector: detector), notes: &notes)
        XCTAssertEqual(out.width, 100)
        XCTAssertTrue(isGreen(TestImages.pixel(of: out, x: 25, y: 50)))
        XCTAssertEqual(TestImages.pixel(of: out, x: 75, y: 50).blue, 255, accuracy: 2)
        XCTAssertEqual(notes, ["Redacted 1 text area"])
    }

    func testTextIsReadFromALargerCopyThanFaces() throws {
        let image = TestImages.make(width: 3000, height: 1000)
        let detector = FakeVisionDetector()
        var notes: [String] = []
        _ = try pipeline([.redact(RedactOptions(target: .both))]).apply(to: image, focus: FocusContext(detector: detector),
                                                                        notes: &notes)
        XCTAssertEqual(detector.recorded.map(\.kind), ["faces", "text"])
        XCTAssertEqual(detector.recorded.first?.width, 2048)
        XCTAssertEqual(detector.recorded.first?.height, 683)
        XCTAssertEqual(notes, [Redaction.nothingFoundNote])
    }

    func testOnlyTheChosenTargetIsDetected() throws {
        let detector = FakeVisionDetector()
        var notes: [String] = []
        _ = try pipeline([.redact(RedactOptions(target: .text))])
            .apply(to: TestImages.make(width: 20, height: 20), focus: FocusContext(detector: detector), notes: &notes)
        XCTAssertEqual(detector.recorded.map(\.kind), ["text"])
    }

    func testNothingFoundLeavesTheImageAndNotes() throws {
        let image = TestImages.noise(width: 30, height: 30)
        var notes: [String] = []
        let out = try pipeline([.redact(RedactOptions())]).apply(to: image, focus: FocusContext(detector: FakeVisionDetector()),
                                                                  notes: &notes)
        XCTAssertTrue(out === image)
        XCTAssertEqual(notes, ["Redact: nothing found"])
    }

    func testAVisionErrorIsANoteNotAFailure() throws {
        let image = TestImages.noise(width: 30, height: 30)
        var notes: [String] = []
        let out = try pipeline([.redact(RedactOptions(target: .both))])
            .apply(to: image, focus: FocusContext(detector: FakeVisionDetector(error: VisionBroke())), notes: &notes)
        XCTAssertTrue(out === image)
        XCTAssertEqual(notes, ["Image analysis unavailable: Vision broke; nothing was redacted"])

        notes = []
        let partial = try pipeline([.redact(fill)]).apply(
            to: TestImages.make(width: 40, height: 40),
            focus: FocusContext(detector: HalfBrokenDetector(text: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)])),
            notes: &notes)
        XCTAssertTrue(isGreen(TestImages.pixel(of: partial, x: 5, y: 5)), "what was found is still hidden")
        XCTAssertEqual(notes, ["Image analysis unavailable: Vision broke; only redacted 1 text area"])
    }

    func testAnUnavailableAnalysisMakesTheReportRowAWarning() {
        let warning = ReportEntry(source: "/a.jpg", status: .succeeded, inputBytes: 1,
                                  note: "Redacted 1 face; Image analysis unavailable: x; nothing was redacted")
        XCTAssertTrue(warning.isWarning)
        XCTAssertFalse(ReportEntry(source: "/a.jpg", status: .succeeded, inputBytes: 1, note: "Redact: nothing found").isWarning)
        XCTAssertFalse(ReportEntry(source: "/a.jpg", status: .succeeded, inputBytes: 1).isWarning)
        XCTAssertFalse(ReportEntry(source: "/a.jpg", status: .failed, inputBytes: 1,
                                   note: "Image analysis unavailable: x").isWarning)
        let html = ReportExporter.html(ProcessingReport(
            summary: RunSummary(startedAt: Date(), finishedAt: Date(), outputMode: "x", total: 1, succeeded: 1, failed: 0,
                                inputBytes: 1, outputBytes: 1), entries: [warning]))
        XCTAssertTrue(html.contains("<td class=\"status warning\">warning</td>"))
    }

    func testBatchPrepareCarriesTheNote() throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 100, height: 100), to: url, type: .png)
        var options = ItemRunOptions()
        options.focus = FocusContext(detector: FakeVisionDetector(faces: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                                                                          CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)]))
        let prepared = try BatchRunner.prepare(url, pipeline: pipeline([.redact(fill)]), assets: .empty,
                                               maxPixels: ImageLoader.defaultMaxPixels, options: options)
        XCTAssertEqual(prepared.notes, ["Redacted 2 faces"])
        XCTAssertTrue(isGreen(TestImages.pixel(of: prepared.image, x: 15, y: 15)))
    }

    func testARedactStepNeverTakesTheLosslessMetadataPath() {
        var redacting = pipeline([.redact(RedactOptions())])
        redacting.metadata = MetadataOptions(removeLocation: true)
        redacting.metadata.isEnabled = true
        redacting.metadata.isIncluded = true
        var metadataOnly = redacting
        metadataOnly.steps = []
        XCTAssertTrue(LosslessMetadata.applies(to: metadataOnly), "the comparison pipeline is metadata-only")
        XCTAssertFalse(LosslessMetadata.applies(to: redacting))
        // Switched off, the step is not a pixel step any more.
        redacting.steps[0].isEnabled = false
        XCTAssertTrue(LosslessMetadata.applies(to: redacting))
    }

    func testRedactKeepsTheSizeAndNeedsNoDecodeHintBeforeIt() {
        let redactFirst = pipeline([.redact(RedactOptions()), .resize(ResizeOptions(mode: .maxWidth(100)))])
        XCTAssertNil(redactFirst.decodeHint(sourceWidth: 4000, sourceHeight: 3000), "Redact needs full-size pixels")
        XCTAssertEqual(redactFirst.outputSize(sourceWidth: 4000, sourceHeight: 3000).width, 100)
        XCTAssertEqual(pipeline([.redact(RedactOptions())]).outputSize(sourceWidth: 40, sourceHeight: 30).height, 30)
    }

    func testPreviewCachesDetectionsAcrossStyleChanges() async throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 100, height: 100), to: url, type: .png)
        let detector = FakeVisionDetector(faces: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)])
        let renderer = PreviewRenderer(detector: detector)
        let item = InputItem(source: url, relativeDirectory: "")
        for style in [RedactStyle.fill, .blur, .pixelate] {
            var options = fill
            options.style = style
            guard case .ready(let result) = await renderer.render(item: item, index: 0,
                                                                  pipeline: pipeline([.redact(options)])) else {
                return XCTFail("preview failed")
            }
            if style == .fill { XCTAssertTrue(isGreen(TestImages.pixel(of: result.after, x: 10, y: 10))) }
        }
        let count = await renderer.redactCache.detectionCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(detector.recorded.map(\.kind), ["faces", "text"])
    }

    func testRealVisionRedactsRenderedText() throws {
        let image = Self.textImage("HELLO 2026")
        let detections = Redaction.detect(.text, in: image, detector: SystemVisionDetector())
        try XCTSkipIf(detections.failure != nil || detections.text.isEmpty, "Vision found no text here (CI virtual machine?)")
        var notes: [String] = []
        let out = try pipeline([.redact(RedactOptions(target: .text, style: .fill, fillColor: .black))])
            .apply(to: image, notes: &notes)
        XCTAssertTrue(notes.first?.hasPrefix("Redacted") == true, "\(notes)")
        // The middle of the text line is now solid black; the white corner is untouched.
        let rect = try XCTUnwrap(Redaction.pixelRects(detections.text, padding: 15, in: CGSize(width: 800, height: 200)).first)
        let middle = TestImages.pixel(of: out, x: Int(rect.midX), y: Int(rect.midY))
        XCTAssertLessThan(middle.red + middle.green + middle.blue, 6)
        XCTAssertEqual(TestImages.pixel(of: out, x: 799, y: 199).red, 255, accuracy: 1)
    }

    /// Black text on white, 800 × 200.
    private static func textImage(_ string: String) -> CGImage {
        let ctx = CGContext(data: nil, width: 800, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 200))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attributes = [kCTFontAttributeName: font,
                          kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes)!)
        ctx.textPosition = CGPoint(x: 30, y: 60)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    func testNewStepsGoWhereTheyBelong() {
        var pipeline = pipeline([.rotateFlip(RotateFlipOptions()), .watermark(WatermarkOptions())])
        pipeline.add(PipelineStep(operation: .adjust(AdjustOptions())))
        pipeline.add(PipelineStep(operation: .redact(RedactOptions())))
        XCTAssertEqual(pipeline.steps.map(\.operation.kind), [.rotateFlip, .redact, .watermark, .adjust])
    }
}
