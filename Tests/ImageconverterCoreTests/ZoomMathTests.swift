import XCTest
@testable import ImageconverterCore

final class ZoomMathTests: XCTestCase {
    private let image = CGSize(width: 4000, height: 3000)
    private let view = CGSize(width: 400, height: 300)

    func testZoomAroundAnchorKeepsAnchorFixed() {
        let anchor = CGPoint(x: 100, y: -50)
        let start = ZoomState(scale: 2, center: CGPoint(x: 0.4, y: 0.6))
        let shownBefore = ZoomMath.displayedSize(imagePixels: image, view: view, scale: start.scale)
        let pointBefore = CGPoint(x: start.center.x + anchor.x / shownBefore.width,
                                  y: start.center.y + anchor.y / shownBefore.height)
        let zoomed = ZoomMath.zoom(start, to: 3, anchor: anchor, imagePixels: image, view: view)
        XCTAssertEqual(zoomed.scale, 3, accuracy: 1e-9)
        let shownAfter = ZoomMath.displayedSize(imagePixels: image, view: view, scale: zoomed.scale)
        XCTAssertEqual(zoomed.center.x + anchor.x / shownAfter.width, pointBefore.x, accuracy: 1e-9)
        XCTAssertEqual(zoomed.center.y + anchor.y / shownAfter.height, pointBefore.y, accuracy: 1e-9)
    }

    func testCenterClampedAtEdges() {
        // At 2× the view shows half of each axis, so the centre stays within 0.25…0.75.
        let shown = ZoomMath.displayedSize(imagePixels: image, view: view, scale: 2)
        let clamped = ZoomMath.clampCenter(CGPoint(x: -1, y: 5), displayed: shown, view: view)
        XCTAssertEqual(clamped.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(clamped.y, 0.75, accuracy: 1e-9)
        // An axis that fits the view is centred.
        let fitted = ZoomMath.clampCenter(CGPoint(x: 0.1, y: 0.9), displayed: view, view: view)
        XCTAssertEqual(fitted, CGPoint(x: 0.5, y: 0.5))
        // Panning far right stops at the right edge.
        let panned = ZoomMath.pan(ZoomState(scale: 2), by: CGSize(width: -10_000, height: 0), imagePixels: image, view: view)
        XCTAssertEqual(panned.center.x, 0.75, accuracy: 1e-9)
    }

    func testScaleClampedToRange() {
        // 4000 px in 400 pt at 2 px/pt: fit is 0.1 pt/px, actual pixels is 5× fit, the maximum 40× fit.
        XCTAssertEqual(ZoomMath.actualPixelsScale(imagePixels: image, view: view, pixelsPerPoint: 2), 5, accuracy: 1e-9)
        let upper = ZoomMath.maxScale(imagePixels: image, view: view, pixelsPerPoint: 2)
        XCTAssertEqual(upper, 40, accuracy: 1e-9)
        XCTAssertEqual(ZoomMath.clampScale(0.3, max: upper), 1)
        XCTAssertEqual(ZoomMath.clampScale(500, max: upper), 40)
        XCTAssertEqual(ZoomMath.clampScale(.nan, max: upper), 1)
        // A tiny image that fits larger than 8× actual pixels cannot be zoomed past fit.
        let tiny = CGSize(width: 10, height: 10)
        XCTAssertEqual(ZoomMath.maxScale(imagePixels: tiny, view: view, pixelsPerPoint: 2), 1)
        let zoomed = ZoomMath.zoom(.fit, to: 0.2, anchor: .zero, imagePixels: image, view: view)
        XCTAssertEqual(zoomed, .fit)
    }
}
