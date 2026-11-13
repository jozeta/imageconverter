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
}
