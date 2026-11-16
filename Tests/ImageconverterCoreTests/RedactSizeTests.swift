import CoreGraphics
import Vision
import XCTest
@testable import ImageconverterCore

/// Pixelate's block size and Blur's radius: Auto (scaled to each box) or a fixed number of pixels.
final class RedactSizeTests: XCTestCase {
    func testAutoScalesWithTheBoxAndFixedIsTheSameForEveryBox() {
        let small = CGRect(x: 0, y: 0, width: 30, height: 21)
        let large = CGRect(x: 0, y: 0, width: 600, height: 300)
        let auto = RedactOptions(style: .pixelate)
        XCTAssertEqual(auto.blockSize(for: small), 7)
        XCTAssertEqual(auto.blockSize(for: large), 100)
        XCTAssertEqual(auto.blurRadius(for: large), 100)
        var fixed = auto
        fixed.fixedBlockSize = 12
        fixed.fixedBlurRadius = 9
        XCTAssertEqual(fixed.blockSize(for: small), 12)
        XCTAssertEqual(fixed.blurRadius(for: small), 9)
        // The safety floor: at least 8 px and a fifth of the box's shorter side (300 → 60).
        XCTAssertEqual(fixed.blockSize(for: large), 60)
        XCTAssertEqual(fixed.blurRadius(for: large), 60)
        XCTAssertTrue(fixed.raisesFixedSize(for: large))
        XCTAssertFalse(fixed.raisesFixedSize(for: small))
        fixed.fixedBlockSize = 4
        XCTAssertEqual(fixed.blockSize(for: small), 8, "never below 8 px")
        XCTAssertEqual(Redaction.minimumFixedSize(for: CGRect(x: 0, y: 0, width: 200, height: 10)), 8)
        XCTAssertEqual(Redaction.minimumFixedSize(for: large), 60)
        XCTAssertFalse(auto.raisesFixedSize(for: large), "Auto is never raised")
        var fill = fixed
        fill.style = .fill
        XCTAssertFalse(fill.raisesFixedSize(for: large), "a solid colour has no size")
    }

    func testRaisedSizesAreNotedOnce() throws {
        let image = TestImages.noise(width: 400, height: 200)
        let boxes = [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                     CGRect(x: 0.6, y: 0, width: 0.02, height: 0.02)]
        // 12 px blocks: below the floor of the two large boxes (20 px), above it for the tiny one (8 px).
        var options = RedactOptions(target: .text, style: .pixelate)
        options.fixedBlockSize = 12
        var notes: [String] = []
        let pipeline = Pipeline(steps: [PipelineStep(operation: .redact(options))])
        _ = try pipeline.apply(to: image, focus: FocusContext(detector: FakeVisionDetector(text: boxes)), notes: &notes)
        XCTAssertEqual(notes, ["Redacted 3 text areas", "Block size raised to keep 2 areas unreadable"])
        options.style = .blur
        options.fixedBlurRadius = 2
        notes = []
        _ = try Pipeline(steps: [PipelineStep(operation: .redact(options))])
            .apply(to: image, focus: FocusContext(detector: FakeVisionDetector(text: [boxes[0]])), notes: &notes)
        XCTAssertEqual(notes, ["Redacted 1 text area", "Blur strength raised to keep 1 area unreadable"])
    }

    func testFixedValuesAreClamped() {
        var options = RedactOptions()
        options.fixedBlockSize = 1
        options.fixedBlurRadius = 5000
        XCTAssertEqual(options.clampedBlockSize, 4)
        XCTAssertEqual(options.clampedBlurRadius, 200)
        options.fixedBlockSize = .nan
        options.fixedBlurRadius = .infinity
        XCTAssertNil(options.clampedBlockSize, "not a number: Auto")
        XCTAssertNil(options.clampedBlurRadius)
        XCTAssertEqual(RedactOptions.blockSizeRange, 4...256)
    }

    func testSavedLenientlyAndOldStepsStayAuto() throws {
        let old = try JSONDecoder().decode(RedactOptions.self,
                                           from: Data(#"{"target":"text","style":"pixelate","padding":15}"#.utf8))
        XCTAssertNil(old.fixedBlockSize)
        XCTAssertNil(old.fixedBlurRadius)
        let encodedOld = try XCTUnwrap(String(data: JSONEncoder().encode(old), encoding: .utf8))
        XCTAssertFalse(encodedOld.contains("blockSize"), "Auto isn't written, so older versions read it as before")
        var options = RedactOptions(target: .faces, style: .pixelate)
        options.fixedBlockSize = 24
        options.fixedBlurRadius = 10
        let data = try JSONEncoder().encode(options)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""blockSize":24"#), json)
        XCTAssertTrue(json.contains(#""blurRadius":10"#), json)
        XCTAssertEqual(try JSONDecoder().decode(RedactOptions.self, from: data), options)
        let odd = try JSONDecoder().decode(RedactOptions.self,
                                           from: Data(#"{"style":"pixelate","blockSize":"big","blurRadius":null}"#.utf8))
        XCTAssertNil(odd.fixedBlockSize)
        XCTAssertNil(odd.fixedBlurRadius)
    }

    func testSummaryNamesAFixedSizeForTheChosenStyle() {
        var options = RedactOptions(style: .pixelate)
        options.fixedBlockSize = 16
        options.fixedBlurRadius = 8
        XCTAssertEqual(options.summary, "faces · pixelate · blocks 16 px")
        options.style = .blur
        XCTAssertEqual(options.summary, "faces · blur · radius 8 px")
        options.style = .fill
        XCTAssertEqual(options.summary, "faces · solid colour")
    }

    func testFixedBlockSizeDrawsBlocksOfThatSize() throws {
        let image = TestImages.noise(width: 80, height: 80)
        let rect = CGRect(x: 0, y: 0, width: 80, height: 80)
        var options = RedactOptions(style: .pixelate)
        options.fixedBlockSize = 4
        let out = try ImageOps.redact(image, options, rects: [rect])
        // Raised to the floor of 16 px (a fifth of 80): blocks start at the box's corner, (0…15) is one colour.
        let first = TestImages.pixel(of: out, x: 0, y: 0)
        let same = TestImages.pixel(of: out, x: 15, y: 15)
        XCTAssertEqual(first.red, same.red, accuracy: 1)
        XCTAssertEqual(first.green, same.green, accuracy: 1)
        var differs = 0
        for block in 1..<5 where abs(TestImages.pixel(of: out, x: block * 16, y: 0).red
                                    - TestImages.pixel(of: out, x: block * 16 - 1, y: 0).red) > 2 {
            differs += 1
        }
        XCTAssertGreaterThan(differs, 2, "16 px blocks, not Auto's 27 px")
    }

    func testFixedBlurRadiusIsRaisedToTheFloorAndUsedAboveIt() throws {
        let image = TestImages.noise(width: 120, height: 120)
        let rect = CGRect(x: 0, y: 0, width: 120, height: 120)
        var light = RedactOptions(style: .blur)
        light.fixedBlurRadius = 2
        var floor = light
        floor.fixedBlurRadius = 24
        let raised = try ImageOps.redact(image, light, rects: [rect])
        let atFloor = try ImageOps.redact(image, floor, rects: [rect])
        XCTAssertEqual(raised.dataProvider?.data as Data?, atFloor.dataProvider?.data as Data?, "2 px is drawn as 24 px")
        var above = light
        above.fixedBlurRadius = 30
        let stronger = try ImageOps.redact(image, above, rects: [rect])
        XCTAssertNotEqual(stronger.dataProvider?.data as Data?, atFloor.dataProvider?.data as Data?,
                          "above the floor the fixed radius is used")
    }

    /// Real Vision reads the result back: the smallest fixed sizes, raised by the floor, leave 40 px text unreadable.
    func testSmallFixedSizesLeaveTextUnreadable() throws {
        let item = RedactCorpus.Case(name: "40 px", width: 1200, height: 400, background: .white,
                                     texts: [RedactCorpus.Text(string: "Membership 77341", font: "Helvetica", size: 40,
                                                               center: CGPoint(x: 600, y: 200))])
        let image = RedactCorpus.image(item)
        let found = Redaction.detect(.text, in: image, detector: SystemVisionDetector())
        try XCTSkipIf(found.failure != nil || found.text.isEmpty, "Vision found no text here (CI virtual machine?)")
        let rects = Redaction.pixelRects(found.text, padding: RedactOptions.defaultPadding,
                                         in: CGSize(width: image.width, height: image.height))
        var pixelate = RedactOptions(target: .text, style: .pixelate)
        pixelate.fixedBlockSize = 4
        var blur = RedactOptions(target: .text, style: .blur)
        blur.fixedBlurRadius = 2
        for options in [pixelate, blur] {
            let out = try ImageOps.redact(image, options, rects: rects)
            let read = try Self.readText(in: out)
            XCTAssertFalse(read.contains("773") || read.contains("341") || read.lowercased().contains("member"),
                           "\(options.summary) read back as \(read)")
        }
    }

    /// Everything accurate recognition reads in `image`.
    private static func readText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
