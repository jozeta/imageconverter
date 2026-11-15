import CoreGraphics
import CoreText
import XCTest
@testable import ImageconverterCore

struct VisionBroke: LocalizedError {
    var errorDescription: String? { "Vision broke" }
}

/// Faces fail, text works (a partial detection).
struct HalfBrokenDetector: VisionDetector {
    let text: [CGRect]
    func faceRects(in image: CGImage) throws -> [CGRect] { throw VisionBroke() }
    func subjectRects(in image: CGImage) throws -> [CGRect] { [] }
    func textRects(in image: CGImage) throws -> [CGRect] { text }
}

final class RedactGeometryTests: XCTestCase {
    func testPixelRectsPadEachSideByAShareOfTheBox() {
        let rects = Redaction.pixelRects([CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)], padding: 10,
                                         in: CGSize(width: 200, height: 100))
        // 100 × 50 box at (50, 25); 10 % → 10 px left/right, 5 px top/bottom.
        XCTAssertEqual(rects, [CGRect(x: 40, y: 20, width: 120, height: 60)])
    }

    func testPixelRectsAreClampedAndWholePixels() {
        let rects = Redaction.pixelRects([CGRect(x: 0.9, y: -0.2, width: 0.3, height: 0.5),
                                          CGRect(x: 0.101, y: 0.101, width: 0.1, height: 0.1)],
                                         padding: 0, in: CGSize(width: 100, height: 100))
        XCTAssertEqual(rects[0], CGRect(x: 90, y: 0, width: 10, height: 30))
        // Floor the start, ceil the end: the whole box is covered.
        XCTAssertEqual(rects[1], CGRect(x: 10, y: 10, width: 11, height: 11))
    }

    func testUntrustedBoxesAreDropped() {
        let rects = Redaction.pixelRects([CGRect(x: CGFloat.nan, y: 0, width: 0.1, height: 0.1),
                                          CGRect(x: 0.2, y: 0.2, width: 0, height: 0.1),
                                          CGRect(x: 2, y: 2, width: 0.5, height: 0.5),
                                          CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)],
                                         padding: 15, in: CGSize(width: 100, height: 100))
        XCTAssertEqual(rects, [])
        XCTAssertEqual(Redaction.pixelRects([CGRect(x: 0, y: 0, width: 1, height: 1)], padding: .nan,
                                            in: CGSize(width: 10, height: 10)),
                       [CGRect(x: 0, y: 0, width: 10, height: 10)])
    }

    func testFilterStrengthScalesWithTheBox() {
        XCTAssertEqual(Redaction.blurRadius(for: CGRect(x: 0, y: 0, width: 400, height: 150)), 50)
        XCTAssertEqual(Redaction.blurRadius(for: CGRect(x: 0, y: 0, width: 10, height: 10)), 6)
        XCTAssertEqual(Redaction.blockSize(for: CGRect(x: 0, y: 0, width: 600, height: 300)), 100)
        XCTAssertEqual(Redaction.blockSize(for: CGRect(x: 0, y: 0, width: 12, height: 12)), 6)
    }

    func testNotes() {
        XCTAssertEqual(Redaction.note(faces: 2, text: 1), "Redacted 2 faces, 1 text area")
        XCTAssertEqual(Redaction.note(faces: 1, text: 0), "Redacted 1 face")
        XCTAssertEqual(Redaction.note(faces: 0, text: 3), "Redacted 3 text areas")
        XCTAssertEqual(Redaction.note(faces: 0, text: 0), "Redact: nothing found")
    }

    func testTargets() {
        XCTAssertEqual(RedactTarget.faces.adding(.text), .both)
        XCTAssertEqual(RedactTarget.text.adding(.text), .text)
        XCTAssertEqual(RedactTarget.both.adding(.faces), .both)
        XCTAssertTrue(RedactTarget.both.includesFaces && RedactTarget.both.includesText)
        XCTAssertFalse(RedactTarget.faces.includesText)
    }
}

final class RedactRenderTests: XCTestCase {
    private let box = CGRect(x: 20, y: 10, width: 30, height: 20)

    /// The image's rows as bytes, for byte-exact comparisons.
    private func rows(_ image: CGImage) throws -> [[UInt8]] {
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let bytes = [UInt8](data)
        let rowBytes = image.width * image.bitsPerPixel / 8
        return (0..<image.height).map { Array(bytes[($0 * image.bytesPerRow)..<($0 * image.bytesPerRow + rowBytes)]) }
    }

    /// Every pixel outside `rect` is byte-identical; at least one inside differs.
    private func assertOnlyInsideChanged(_ input: CGImage, _ output: CGImage, rect: CGRect,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(output.width, input.width, file: file, line: line)
        XCTAssertEqual(output.height, input.height, file: file, line: line)
        XCTAssertEqual(output.bitsPerPixel, input.bitsPerPixel, file: file, line: line)
        XCTAssertEqual(output.alphaInfo, input.alphaInfo, file: file, line: line)
        let before = try rows(input)
        let after = try rows(output)
        let bytesPerPixel = input.bitsPerPixel / 8
        var changedInside = false
        for row in 0..<input.height {
            for col in 0..<input.width {
                let range = (col * bytesPerPixel)..<((col + 1) * bytesPerPixel)
                let same = before[row][range] == after[row][range]
                if rect.contains(CGPoint(x: Double(col) + 0.5, y: Double(row) + 0.5)) {
                    if !same { changedInside = true }
                } else if !same {
                    return XCTFail("pixel (\(col), \(row)) outside the box changed", file: file, line: line)
                }
            }
        }
        XCTAssertTrue(changedInside, "nothing inside the box changed", file: file, line: line)
    }

    func testBlurChangesOnlyInsideTheBox() throws {
        let image = TestImages.noise(width: 80, height: 60)
        let out = try ImageOps.redact(image, RedactOptions(style: .blur), rects: [box])
        try assertOnlyInsideChanged(image, out, rect: box)
    }

    func testPixelateChangesOnlyInsideTheBox() throws {
        let image = TestImages.noise(width: 80, height: 60)
        let out = try ImageOps.redact(image, RedactOptions(style: .pixelate), rects: [box])
        try assertOnlyInsideChanged(image, out, rect: box)
        // Blocks of 7 px (a third of 20, rounded up): neighbours in one block are equal.
        let inside = TestImages.pixel(of: out, x: 20, y: 10)
        let next = TestImages.pixel(of: out, x: 21, y: 11)
        XCTAssertEqual(inside.red, next.red, accuracy: 1)
    }

    func testFillIsOpaqueAndOnlyInsideTheBox() throws {
        let image = TestImages.noise(width: 80, height: 60)
        let color = RGBAColor(red: 0, green: 1, blue: 0, alpha: 0.2)
        let out = try ImageOps.redact(image, RedactOptions(style: .fill, fillColor: color), rects: [box])
        try assertOnlyInsideChanged(image, out, rect: box)
        let pixel = TestImages.pixel(of: out, x: 35, y: 20)
        XCTAssertEqual(pixel.alpha, 255)
        XCTAssertEqual(pixel.green, 255, accuracy: 2)
        XCTAssertEqual(pixel.red, 0, accuracy: 2)
    }

    func testBlurHidesDetail() throws {
        let image = TestImages.noise(width: 120, height: 120)
        let rect = CGRect(x: 10, y: 10, width: 100, height: 100)
        let out = try ImageOps.redact(image, RedactOptions(style: .blur), rects: [rect])
        // Noise has neighbour differences of ~85 on average; blurred it is nearly flat.
        var difference = 0.0
        for col in 40..<80 {
            difference += abs(TestImages.pixel(of: out, x: col, y: 60).red - TestImages.pixel(of: out, x: col + 1, y: 60).red)
        }
        XCTAssertLessThan(difference / 40, 10)
    }

    func testNoRectsReturnTheImageItself() throws {
        let image = TestImages.noise(width: 10, height: 10)
        XCTAssertTrue(try ImageOps.redact(image, RedactOptions(), rects: []) === image)
        XCTAssertTrue(try ImageOps.redact(image, RedactOptions(), rects: [CGRect(x: 50, y: 50, width: 5, height: 5)])
                      === image)
    }

    func testSixteenBitImagesKeepTheirDepth() throws {
        let image = TestImages.displayP3(width: 40, height: 40)
        let out = try ImageOps.redact(image, RedactOptions(style: .blur), rects: [CGRect(x: 5, y: 5, width: 10, height: 10)])
        XCTAssertEqual(out.bitsPerComponent, 16)
        XCTAssertEqual(out.colorSpace?.name, image.colorSpace?.name)
    }
}

final class RedactModelTests: XCTestCase {
    func testOptionsRoundTripAndDecodeLeniently() throws {
        let options = RedactOptions(target: .both, style: .pixelate,
                                    fillColor: RGBAColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1), padding: 25)
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(RedactOptions.self, from: data), options)
        XCTAssertEqual(try JSONDecoder().decode(RedactOptions.self, from: Data("{}".utf8)), RedactOptions())
        let odd = try JSONDecoder().decode(RedactOptions.self,
                                           from: Data(#"{"target":"cars","style":"smudge","padding":"x"}"#.utf8))
        XCTAssertEqual(odd, RedactOptions())
    }

    func testPipelineRoundTrip() throws {
        let pipeline = Pipeline(steps: [PipelineStep(operation: .crop(CropOptions())),
                                        PipelineStep(operation: .redact(RedactOptions(target: .text, style: .pixelate))),
                                        PipelineStep(operation: .watermark(WatermarkOptions()))])
        let decoded = try JSONDecoder().decode(Pipeline.self, from: JSONEncoder().encode(pipeline))
        XCTAssertEqual(decoded, pipeline)
    }

    func testDefaults() {
        let options = RedactOptions()
        XCTAssertEqual(options.target, .faces)
        XCTAssertEqual(options.style, .blur)
        XCTAssertEqual(options.padding, 15)
        XCTAssertEqual(StepKind.redact.defaultOperation, .redact(options))
        XCTAssertEqual(RedactOptions(padding: 400).clampedPadding, 100)
        XCTAssertEqual(RedactOptions(padding: .nan).clampedPadding, 15)
    }

    func testSummaryAndHelp() {
        XCTAssertEqual(ImageOperation.redact(RedactOptions()).summary, "faces · blur")
        XCTAssertEqual(ImageOperation.redact(RedactOptions(target: .both, style: .fill, padding: 0)).summary,
                       "faces and text · solid colour · padding 0 %")
        let help = StepHelp.info(for: .redact)
        XCTAssertEqual(help.title, "Redact")
        XCTAssertTrue(help.tips.joined().contains("Best effort"))
    }

    func testDefaultOrderPutsRedactAfterCropAndRotate() {
        let kinds = StepKind.allCases
        XCTAssertEqual(kinds.firstIndex(of: .redact), kinds.firstIndex(of: .rotateFlip).map { $0 + 1 })
        var pipeline = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions())),
                                        PipelineStep(operation: .crop(CropOptions())),
                                        PipelineStep(operation: .adjust(AdjustOptions())),
                                        PipelineStep(operation: .watermark(WatermarkOptions()))])
        XCTAssertEqual(pipeline.redactInsertionIndex, 2)
        XCTAssertEqual(Pipeline(steps: [PipelineStep(operation: .watermark(WatermarkOptions()))]).redactInsertionIndex, 0)

        let id = pipeline.addRedaction(.faces)
        XCTAssertEqual(pipeline.steps[2].id, id)
        // Faces again: already covered.
        XCTAssertEqual(pipeline.addRedaction(.faces), id)
        XCTAssertEqual(pipeline.steps.count, 5)
    }
}
