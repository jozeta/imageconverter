import XCTest
@testable import ImageconverterCore

final class GeometryTests: XCTestCase {
    private func size(_ width: Double, _ height: Double) -> CGSize { CGSize(width: width, height: height) }

    private func plan(_ width: Double, _ height: Double, _ mode: ResizeMode, enlarge: Bool = false) -> ResizePlan {
        Geometry.resizePlan(source: size(width, height), options: ResizeOptions(mode: mode, allowEnlarge: enlarge))
    }

    func testDontEnlargeSmallImage() {
        XCTAssertEqual(plan(300, 200, .maxWidth(1600)), .unchanged)
    }

    func testMaxWidthKeepsAspect() {
        XCTAssertEqual(plan(4000, 3000, .maxWidth(1600)), .scale(to: size(1600, 1200)))
    }

    func testFitBoxPicksTighterSide() {
        XCTAssertEqual(plan(4000, 1000, .fitBox(width: 1600, height: 1200)), .scale(to: size(1600, 400)))
    }

    func testExactSizeModes() {
        XCTAssertEqual(plan(4000, 3000, .exactSize(width: 1000, height: 1000, fill: .stretch)),
                       .scale(to: size(1000, 1000)))
        XCTAssertEqual(plan(4000, 3000, .exactSize(width: 1000, height: 1000, fill: .fitAndPad)),
                       .fitAndPad(content: size(1000, 750), canvas: size(1000, 1000)))
        XCTAssertEqual(plan(4000, 3000, .exactSize(width: 1000, height: 1000, fill: .fillAndCrop)),
                       .fillAndCrop(scaled: size(1333, 1000), crop: size(1000, 1000)))
    }

    func testExactSizeWithoutEnlargeStillPadsAndCrops() {
        // 300x200 into 1000x1000: content is capped at the source size, canvas is the full target.
        XCTAssertEqual(plan(300, 200, .exactSize(width: 1000, height: 1000, fill: .fitAndPad)),
                       .fitAndPad(content: size(300, 200), canvas: size(1000, 1000)))
        // Crops the unscaled source to at most the target size.
        XCTAssertEqual(plan(300, 200, .exactSize(width: 1000, height: 100, fill: .fillAndCrop)),
                       .fillAndCrop(scaled: size(300, 200), crop: size(300, 100)))
        // Stretch always scales.
        XCTAssertEqual(plan(300, 200, .exactSize(width: 1000, height: 1000, fill: .stretch)),
                       .scale(to: size(1000, 1000)))
    }

    func testExactWidthAndHeight() {
        XCTAssertEqual(plan(4000, 3000, .exactWidth(1000)), .scale(to: size(1000, 750)))
        XCTAssertEqual(plan(4000, 3000, .exactHeight(600)), .scale(to: size(800, 600)))
        XCTAssertEqual(plan(300, 200, .exactWidth(600)), .unchanged)
        XCTAssertEqual(plan(300, 200, .exactWidth(600), enlarge: true), .scale(to: size(600, 400)))
    }

    func testAllowEnlarge() {
        XCTAssertEqual(plan(300, 200, .maxWidth(600), enlarge: true), .scale(to: size(600, 400)))
    }

    func testCropAspectCentered() {
        let rect = Geometry.cropRect(source: size(4000, 3000),
                                     options: CropOptions(mode: .aspect(width: 1, height: 1), anchor: .center))
        XCTAssertEqual(rect, CGRect(x: 500, y: 0, width: 3000, height: 3000))
    }

    func testCropSizeClampedAndAnchored() {
        let rect = Geometry.cropRect(source: size(400, 300),
                                     options: CropOptions(mode: .size(width: 1000, height: 100), anchor: .bottomRight))
        XCTAssertEqual(rect, CGRect(x: 0, y: 200, width: 400, height: 100))
    }

    func testCanvasPaddingAndPercent() {
        let pad = Geometry.canvas(source: size(400, 300), options: CanvasOptions(mode: .padding(pixels: 20)))
        XCTAssertEqual(pad.canvas, size(440, 340))
        XCTAssertEqual(pad.imageOrigin, CGPoint(x: 20, y: 20))
        let pct = Geometry.canvas(source: size(400, 300), options: CanvasOptions(mode: .paddingPercent(5)))
        XCTAssertEqual(pct.canvas, size(430, 330))
        XCTAssertEqual(pct.imageOrigin, CGPoint(x: 15, y: 15))
    }

    func testCanvasFixedSmallerClips() {
        let result = Geometry.canvas(source: size(400, 300),
                                     options: CanvasOptions(mode: .size(width: 200, height: 200), anchor: .center))
        XCTAssertEqual(result.canvas, size(200, 200))
        XCTAssertEqual(result.imageOrigin, CGPoint(x: -100, y: -50))
    }

    func testNonsenseValuesAreClamped() {
        // maxWidth(0) -> width 1, height rounds to max(1, 0.75) = 1.
        XCTAssertEqual(plan(400, 300, .maxWidth(0)), .scale(to: size(1, 1)))
        XCTAssertEqual(plan(400, 300, .maxWidth(-5)), .scale(to: size(1, 1)))
        // aspect(0, 5) is treated as 1:5: on 400x300 -> 60x300 centred at x 170.
        XCTAssertEqual(Geometry.cropRect(source: size(400, 300),
                                         options: CropOptions(mode: .aspect(width: 0, height: 5), anchor: .center)),
                       CGRect(x: 170, y: 0, width: 60, height: 300))
        XCTAssertEqual(Geometry.cropRect(source: size(400, 300),
                                         options: CropOptions(mode: .aspect(width: .nan, height: 1), anchor: .topLeft)),
                       CGRect(x: 0, y: 0, width: 300, height: 300))
        // crop size 0 -> 1x1.
        XCTAssertEqual(Geometry.cropRect(source: size(400, 300),
                                         options: CropOptions(mode: .size(width: 0, height: -3), anchor: .topLeft)),
                       CGRect(x: 0, y: 0, width: 1, height: 1))
        // Negative padding and NaN / negative percent leave the canvas unchanged.
        for mode in [CanvasMode.padding(pixels: -10), .paddingPercent(.nan), .paddingPercent(-50)] {
            let result = Geometry.canvas(source: size(400, 300), options: CanvasOptions(mode: mode))
            XCTAssertEqual(result.canvas, size(400, 300))
            XCTAssertEqual(result.imageOrigin, .zero)
        }
        // Fixed canvas below 1 clamps to 1.
        XCTAssertEqual(Geometry.canvas(source: size(400, 300),
                                       options: CanvasOptions(mode: .size(width: 0, height: -1), anchor: .topLeft)).canvas,
                       size(1, 1))
    }

    func testAnchorOrigins() {
        let content = size(10, 10)
        XCTAssertEqual(Anchor.topLeft.origin(content: content, container: size(30, 30)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(Anchor.center.origin(content: content, container: size(30, 30)), CGPoint(x: 10, y: 10))
        XCTAssertEqual(Anchor.bottomRight.origin(content: content, container: size(30, 30)), CGPoint(x: 20, y: 20))
        XCTAssertEqual(Anchor.top.origin(content: content, container: size(30, 30)), CGPoint(x: 10, y: 0))
        XCTAssertEqual(Anchor.left.origin(content: content, container: size(30, 30)), CGPoint(x: 0, y: 10))
        XCTAssertEqual(Anchor.center.origin(content: content, container: size(25, 25)), CGPoint(x: 7, y: 7))
    }

    // MARK: New resize modes

    func testPercent50() {
        XCTAssertEqual(plan(4000, 3000, .percent(50)), .scale(to: size(2000, 1500)))
        XCTAssertEqual(plan(300, 200, .percent(200)), .unchanged)
        XCTAssertEqual(plan(300, 200, .percent(200), enlarge: true), .scale(to: size(600, 400)))
        // Clamped to 1...1000 %; non-finite is 100 %.
        XCTAssertEqual(plan(1000, 500, .percent(0)), .scale(to: size(10, 5)))
        XCTAssertEqual(plan(10, 5, .percent(5000), enlarge: true), .scale(to: size(100, 50)))
        XCTAssertEqual(plan(10, 5, .percent(.nan)), .unchanged)
    }

    func testLongestEdgePortraitAndLandscape() {
        XCTAssertEqual(plan(4000, 3000, .longestEdge(2000)), .scale(to: size(2000, 1500)))
        XCTAssertEqual(plan(3000, 4000, .longestEdge(2000)), .scale(to: size(1500, 2000)))
        XCTAssertEqual(plan(300, 200, .longestEdge(2000)), .unchanged)
    }

    func testShortestEdge() {
        XCTAssertEqual(plan(4000, 3000, .shortestEdge(1500)), .scale(to: size(2000, 1500)))
        XCTAssertEqual(plan(3000, 4000, .shortestEdge(1500)), .scale(to: size(1500, 2000)))
    }

    func testMinimumUpscalesOnlyWhenSmaller() {
        // Ignores "don't enlarge": that is the point of the mode.
        XCTAssertEqual(plan(300, 200, .minimum(width: 600, height: 300)), .scale(to: size(600, 400)))
        XCTAssertEqual(plan(300, 200, .minimum(width: 100, height: 300)), .scale(to: size(450, 300)))
        XCTAssertEqual(plan(4000, 3000, .minimum(width: 600, height: 300)), .unchanged)
        XCTAssertEqual(plan(600, 400, .minimum(width: 600, height: 400)), .unchanged)
    }

    func testPhysicalCentimetresAt300DPI() {
        XCTAssertEqual(Geometry.physicalPixels(10, unit: .centimetre, dpi: 300), 1181)
        XCTAssertEqual(Geometry.physicalPixels(4, unit: .inch, dpi: 300), 1200)
        XCTAssertNil(Geometry.physicalPixels(.nan, unit: .inch, dpi: 300))
        XCTAssertNil(Geometry.physicalPixels(4, unit: .inch, dpi: 0))
        XCTAssertEqual(plan(4000, 3000, .physical(width: 10, height: 10, unit: .centimetre, dpi: 300)),
                       .scale(to: size(1181, 886)))
    }

    func testPhysicalOneSideKeepsAspect() {
        XCTAssertEqual(plan(4000, 3000, .physical(width: 4, height: nil, unit: .inch, dpi: 300)),
                       .scale(to: size(1200, 900)))
        XCTAssertEqual(plan(4000, 3000, .physical(width: nil, height: 2, unit: .inch, dpi: 300)),
                       .scale(to: size(800, 600)))
        XCTAssertEqual(plan(4000, 3000, .physical(width: nil, height: nil, unit: .inch, dpi: 300)), .unchanged)
    }

    func testOldResizeJSONDecodes() throws {
        let json = #"{"mode":{"exactSize":{"width":800,"height":600,"fill":"fillAndCrop"}},"#
            + #""allowEnlarge":true,"padColor":{"red":0,"green":0,"blue":0,"alpha":1}}"#
        let options = try JSONDecoder().decode(ResizeOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.mode, .exactSize(width: 800, height: 600, fill: .fillAndCrop))
        XCTAssertTrue(options.allowEnlarge)
        XCTAssertEqual(options.resampling, .lanczos)
        XCTAssertNil(options.dpi)

        let fresh = ResizeOptions(mode: .physical(width: 10, height: nil, unit: .centimetre, dpi: 300),
                                  resampling: .nearest, dpi: 72)
        let decoded = try JSONDecoder().decode(ResizeOptions.self, from: JSONEncoder().encode(fresh))
        XCTAssertEqual(decoded, fresh)
        XCTAssertEqual(decoded.effectiveDPI, 300)
    }

    func testOutputDPILastResizeStepWins() {
        var pipeline = Pipeline(steps: [
            PipelineStep(operation: .resize(ResizeOptions(dpi: 72))),
            PipelineStep(operation: .resize(ResizeOptions(mode: .percent(100), dpi: 300))),
            PipelineStep(operation: .resize(ResizeOptions(mode: .percent(100))))
        ])
        XCTAssertEqual(pipeline.outputDPI, 300)
        pipeline.steps[1].isEnabled = false
        XCTAssertEqual(pipeline.outputDPI, 72)
        pipeline.steps[0].isEnabled = false
        XCTAssertNil(pipeline.outputDPI)
    }

    func testOutputSizeKnowsNewModes() {
        let pipeline = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(1000))))])
        XCTAssertEqual(pipeline.outputSize(sourceWidth: 3000, sourceHeight: 4000).width, 750)
        XCTAssertEqual(pipeline.peakPixels(sourceWidth: 300, sourceHeight: 200), 60_000)
        let upscale = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .minimum(width: 600, height: 400))))])
        XCTAssertEqual(upscale.peakPixels(sourceWidth: 300, sourceHeight: 200), 240_000)
    }

    func testNewModeSummaries() {
        func text(_ options: ResizeOptions) -> String { ImageOperation.resize(options).summary }
        XCTAssertEqual(text(ResizeOptions(mode: .percent(50))), "50 %")
        XCTAssertEqual(text(ResizeOptions(mode: .longestEdge(2000), resampling: .nearest, dpi: 300)),
                       "longest edge 2000 px · nearest neighbour · 300 dpi")
        XCTAssertEqual(text(ResizeOptions(mode: .minimum(width: 600, height: 400))), "at least 600 × 400")
        XCTAssertEqual(text(ResizeOptions(mode: .physical(width: 10, height: nil, unit: .centimetre, dpi: 300), dpi: 72)),
                       "10 × auto cm at 300 dpi")
        XCTAssertEqual(text(ResizeOptions()), "max width 1600 px")
    }
}
