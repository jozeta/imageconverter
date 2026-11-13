import XCTest
@testable import ImageconverterCore

final class PipelineModelTests: XCTestCase {
    func testDefaultsPerKind() {
        XCTAssertEqual(StepKind.resize.defaultOperation,
                       .resize(ResizeOptions(mode: .maxWidth(1600), allowEnlarge: false, padColor: .white)))
        XCTAssertEqual(StepKind.crop.defaultOperation, .crop(CropOptions(mode: .aspect(width: 1, height: 1), anchor: .center)))
        XCTAssertEqual(StepKind.rotateFlip.defaultOperation,
                       .rotateFlip(RotateFlipOptions(rotation: .cw90, flipHorizontal: false, flipVertical: false)))
        XCTAssertEqual(StepKind.canvas.defaultOperation,
                       .canvas(CanvasOptions(mode: .padding(pixels: 20), anchor: .center, background: .white)))
        XCTAssertEqual(StepKind.colorProfile.defaultOperation, .colorProfile(.sRGB))
        for kind in StepKind.allCases { XCTAssertEqual(kind.defaultOperation.kind, kind) }
        XCTAssertEqual(StepKind.allCases.map(\.displayName),
                       ["Resize", "Crop", "Rotate / flip", "Canvas / padding", "Color profile"])
    }

    func testPipelineCodableRoundTrip() throws {
        var pipeline = Pipeline()
        pipeline.steps = [
            PipelineStep(operation: .resize(ResizeOptions(mode: .exactSize(width: 800, height: 600, fill: .fillAndCrop),
                                                          allowEnlarge: true, padColor: .black))),
            PipelineStep(isEnabled: false, operation: .crop(CropOptions(mode: .size(width: 100, height: 50), anchor: .topLeft))),
            PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw270, flipHorizontal: true, flipVertical: true))),
            PipelineStep(operation: .canvas(CanvasOptions(mode: .paddingPercent(5.5), anchor: .bottom,
                                                          background: RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.5)))),
            PipelineStep(operation: .colorProfile(.displayP3))
        ]
        let data = try JSONEncoder().encode(pipeline)
        XCTAssertTrue(String(bytes: data, encoding: .utf8)?.contains("\"schemaVersion\":1") == true)
        XCTAssertEqual(try JSONDecoder().decode(Pipeline.self, from: data), pipeline)
    }

    func testSummaries() {
        func resize(_ mode: ResizeMode) -> String { ImageOperation.resize(ResizeOptions(mode: mode)).summary }
        XCTAssertEqual(resize(.maxWidth(1600)), "max width 1600 px")
        XCTAssertEqual(resize(.maxHeight(1200)), "max height 1200 px")
        XCTAssertEqual(resize(.fitBox(width: 1600, height: 1200)), "fit 1600 × 1200")
        XCTAssertEqual(resize(.exactWidth(1600)), "width 1600 px")
        XCTAssertEqual(resize(.exactHeight(1200)), "height 1200 px")
        XCTAssertEqual(resize(.exactSize(width: 1600, height: 1200, fill: .stretch)), "1600 × 1200 · stretch")
        XCTAssertEqual(resize(.exactSize(width: 1600, height: 1200, fill: .fitAndPad)), "1600 × 1200 · pad")
        XCTAssertEqual(resize(.exactSize(width: 1600, height: 1200, fill: .fillAndCrop)), "1600 × 1200 · crop")
        XCTAssertEqual(ImageOperation.crop(CropOptions(mode: .size(width: 1200, height: 800), anchor: .center)).summary,
                       "1200 × 800 px · center")
        XCTAssertEqual(ImageOperation.crop(CropOptions(mode: .aspect(width: 4, height: 5), anchor: .top)).summary, "4:5 · top")
        XCTAssertEqual(ImageOperation.crop(CropOptions(mode: .aspect(width: 1.91, height: 1), anchor: .bottomRight)).summary,
                       "1.91:1 · bottom right")
        func rf(_ rotation: Rotation, _ flipH: Bool, _ flipV: Bool) -> String {
            ImageOperation.rotateFlip(RotateFlipOptions(rotation: rotation, flipHorizontal: flipH, flipVertical: flipV)).summary
        }
        XCTAssertEqual(rf(.cw90, true, false), "90° · flip H")
        XCTAssertEqual(rf(.none, false, false), "no change")
        XCTAssertEqual(rf(.none, false, true), "flip V")
        XCTAssertEqual(rf(.cw180, true, true), "180° · flip H+V")
        func canvas(_ mode: CanvasMode) -> String { ImageOperation.canvas(CanvasOptions(mode: mode)).summary }
        XCTAssertEqual(canvas(.padding(pixels: 20)), "+20 px")
        XCTAssertEqual(canvas(.paddingPercent(5)), "+5 %")
        XCTAssertEqual(canvas(.size(width: 2000, height: 2000)), "2000 × 2000")
        XCTAssertEqual(ImageOperation.colorProfile(.displayP3).summary, "Display P3")
    }

    func testAnchorDisplayNames() {
        XCTAssertEqual(Anchor.allCases.map(\.displayName),
                       ["top left", "top", "top right", "left", "center", "right", "bottom left", "bottom", "bottom right"])
    }

    func testSummariesNeverTrapOnNonFiniteOrHugeValues() {
        let crops: [Double] = [.infinity, 1e30, .nan, -.infinity]
        for value in crops {
            let crop = ImageOperation.crop(CropOptions(mode: .aspect(width: value, height: 1)))
            XCTAssertFalse(crop.summary.isEmpty)
            XCTAssertFalse(ImageOperation.canvas(CanvasOptions(mode: .paddingPercent(value))).summary.isEmpty)
        }
    }

    func testSummaryRoundsFloatingPointNoise() {
        let crop = ImageOperation.crop(CropOptions(mode: .aspect(width: 0.1 + 0.2, height: 1), anchor: .center))
        XCTAssertEqual(crop.summary, "0.3:1 · center")
    }
}
