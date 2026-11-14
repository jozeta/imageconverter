import XCTest
@testable import ImageconverterCore

final class WindowLayoutTests: XCTestCase {
    private let screen = CGSize(width: 2000, height: 1200)

    private func target(shown: Bool, current: CGSize, content: CGFloat, width: CGFloat? = nil,
                        maxContent: CGSize? = nil) -> CGSize {
        WindowLayout.targetSize(previewShown: shown, current: current, contentHeight: content,
                                requestedWidth: width, maxContent: maxContent ?? screen)
    }

    // MARK: Limits

    func testPreviewOpenLimitsResizeInWidthOnlyAndFixTheHeight() {
        let limits = WindowLayout.limits(previewShown: true, fittedHeight: 681, maxContent: screen)
        XCTAssertEqual(limits.width, 780...CGFloat.infinity)
        XCTAssertEqual(limits.height, 681...681)
    }

    func testPreviewHiddenLimitsAreFixed() {
        let limits = WindowLayout.limits(previewShown: false, fittedHeight: 640, maxContent: screen)
        XCTAssertEqual(limits.width, 360...360)
        XCTAssertEqual(limits.height, 640...640)
    }

    func testOpenLimitsShrinkOnASmallScreen() {
        let limits = WindowLayout.limits(previewShown: true, fittedHeight: 400,
                                         maxContent: CGSize(width: 700, height: 400))
        XCTAssertEqual(limits.width.lowerBound, 700)
        XCTAssertEqual(limits.height, 400...400)
    }

    func testTransitionalLimitsCoverBothSizes() {
        let final = WindowLayout.limits(previewShown: false, fittedHeight: 300, maxContent: screen)
        let during = WindowLayout.transitional(final, current: CGSize(width: 900, height: 700),
                                               target: CGSize(width: 360, height: 300))
        XCTAssertEqual(during.width, 360...900)
        XCTAssertEqual(during.height, 300...700)
    }

    // MARK: Target size

    func testHiddenHeightIsTheContentHeight() {
        XCTAssertEqual(target(shown: false, current: CGSize(width: 900, height: 900), content: 327),
                       CGSize(width: 360, height: 327))
    }

    func testOpenHeightIsTheContentHeightToo() {
        // Johan: no empty space under Run with the preview open either (no 560 minimum).
        XCTAssertEqual(target(shown: true, current: CGSize(width: 900, height: 681), content: 327),
                       CGSize(width: 900, height: 327))
        XCTAssertEqual(target(shown: true, current: CGSize(width: 900, height: 327), content: 681),
                       CGSize(width: 900, height: 681))
    }

    func testAUserEnlargedHeightIsNotKept() {
        XCTAssertEqual(target(shown: true, current: CGSize(width: 900, height: 900), content: 500).height, 500)
    }

    func testTinyContentGetsTheAbsoluteMinimum() {
        XCTAssertEqual(target(shown: false, current: CGSize(width: 360, height: 400), content: 120).height,
                       WindowLayout.minContentHeight)
        XCTAssertEqual(target(shown: true, current: CGSize(width: 900, height: 400), content: 120).height,
                       WindowLayout.minContentHeight)
    }

    func testHeightIsClampedToTheScreen() {
        XCTAssertEqual(target(shown: false, current: CGSize(width: 360, height: 300), content: 1500).height, 1200)
        XCTAssertEqual(target(shown: true, current: CGSize(width: 900, height: 300), content: 1500).height, 1200)
    }

    func testShowingUsesRequestedWidthAndTheContentHeight() {
        XCTAssertEqual(target(shown: true, current: CGSize(width: 360, height: 327), content: 327, width: 900),
                       CGSize(width: 900, height: 327))
    }

    func testOpenWidthNeverBelowMinimumOrAboveScreen() {
        XCTAssertEqual(target(shown: true, current: CGSize(width: 500, height: 600), content: 600).width, 780)
        XCTAssertEqual(target(shown: true, current: CGSize(width: 900, height: 600), content: 600, width: 5000).width,
                       2000)
    }

    // MARK: Frame

    func testFrameKeepsTheTopLeftCorner() {
        let current = CGRect(x: 100, y: 300, width: 900, height: 709)
        let frame = WindowLayout.frame(contentSize: CGSize(width: 360, height: 327), chrome: CGSize(width: 0, height: 28),
                                       currentFrame: current, visible: CGRect(x: 0, y: 0, width: 2000, height: 1300))
        XCTAssertEqual(frame, CGRect(x: 100, y: 1009 - 355, width: 360, height: 355))
    }

    func testFrameStaysInsideTheVisibleArea() {
        let visible = CGRect(x: 0, y: 50, width: 1000, height: 900)
        let current = CGRect(x: 600, y: 500, width: 360, height: 300)
        let frame = WindowLayout.frame(contentSize: CGSize(width: 900, height: 800), chrome: CGSize(width: 0, height: 28),
                                       currentFrame: current, visible: visible)
        XCTAssertEqual(frame.maxX, 1000)
        XCTAssertEqual(frame.minY, 50)
        XCTAssertEqual(frame.size, CGSize(width: 900, height: 828))
    }
}
