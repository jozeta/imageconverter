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

    // MARK: Expanded pipeline (user-resizable height)

    /// top 300 + gap 4 + steps 200 + 12 + output 220 + 12 + bottom 40 + chrome 48.
    private let parts = WindowLayout.SidebarParts(top: 300, steps: 200, output: 220, bottom: 40, chrome: 48,
                                                  stepsGap: 4, spacing: 12)

    func testSidebarPartHeights() {
        XCTAssertEqual(parts.collapsed, 48 + 300 + 12 + 40)
        XCTAssertEqual(parts.expanded, 400 + 4 + 200 + 12 + 220)
        // The steps keep a strip of at least 60 pt; the fixed gap above Output stays.
        XCTAssertEqual(parts.expandedMinimum, 400 + 4 + 60 + 12 + 220)
        var short = parts
        short.steps = 30
        XCTAssertEqual(short.expandedMinimum, short.expanded)
    }

    func testExpandedWithoutAChosenHeightFitsTheContent() {
        let result = WindowLayout.expandedHeight(parts: parts, remembered: nil, previousContent: nil, maxContent: screen)
        XCTAssertEqual(result.height, parts.expanded)
        XCTAssertNil(result.remembered)
    }

    func testAChosenTallerHeightIsKeptWhenTheContentShrinks() {
        var smaller = parts
        smaller.steps = 100
        let result = WindowLayout.expandedHeight(parts: smaller, remembered: 1100, previousContent: parts.expanded,
                                                 maxContent: screen)
        XCTAssertEqual(result.height, 1100)
        XCTAssertEqual(result.remembered, 1100)
    }

    func testContentGrowingPastATallWindowGrowsItUpToTheScreen() {
        var bigger = parts
        bigger.steps = 400
        let result = WindowLayout.expandedHeight(parts: bigger, remembered: parts.expanded + 50,
                                                 previousContent: parts.expanded, maxContent: screen)
        XCTAssertEqual(result.height, bigger.expanded)
        XCTAssertEqual(result.remembered, bigger.expanded)
        bigger.steps = 2000
        XCTAssertEqual(WindowLayout.expandedHeight(parts: bigger, remembered: parts.expanded,
                                                   previousContent: parts.expanded, maxContent: screen).height, 1200)
    }

    func testAChosenShorterHeightStaysShorterWhenStepsAreAdded() {
        // The user made it shorter than the content (the steps scroll): adding a step keeps their height.
        var bigger = parts
        bigger.steps = 260
        let chosen = parts.expanded - 100
        let result = WindowLayout.expandedHeight(parts: bigger, remembered: chosen, previousContent: parts.expanded,
                                                 maxContent: screen)
        XCTAssertEqual(result.height, chosen)
        XCTAssertEqual(result.remembered, chosen)
    }

    func testAChosenHeightIsClampedToTheMinimumAndTheScreen() {
        XCTAssertEqual(WindowLayout.expandedHeight(parts: parts, remembered: 200, previousContent: nil,
                                                   maxContent: screen).height, parts.expandedMinimum)
        XCTAssertEqual(WindowLayout.expandedHeight(parts: parts, remembered: 5000, previousContent: nil,
                                                   maxContent: screen).height, 1200)
    }

    func testRestHeightsAreFixedWhenCollapsedAndResizableWhenExpanded() {
        XCTAssertEqual(WindowLayout.restHeights(collapsed: true, parts: parts, height: 400, maxContent: screen),
                       400...400)
        XCTAssertEqual(WindowLayout.restHeights(collapsed: false, parts: parts, height: 900, maxContent: screen),
                       parts.expandedMinimum...1200)
        let limits = WindowLayout.limits(previewShown: false, heights: 700...1200, maxContent: screen)
        XCTAssertEqual(limits.width, 360...360)
        XCTAssertEqual(limits.height, 700...1200)
    }

    func testFollowingHeightsAllowAnythingOnTheScreen() {
        XCTAssertEqual(WindowLayout.followingHeights(maxContent: screen), WindowLayout.minContentHeight...1200)
    }
}

/// The metadata panel right of the preview widens the open preview's minimum by its width.
final class WindowLayoutInspectorTests: XCTestCase {
    private let screen = CGSize(width: 1800, height: 1100)

    func testOpenPanelAddsItsWidthToTheMinimum() {
        let closed = WindowLayout.limits(previewShown: true, fittedHeight: 600, maxContent: screen)
        let open = WindowLayout.limits(previewShown: true, fittedHeight: 600, maxContent: screen, inspectorWidth: 300)
        XCTAssertEqual(open.width.lowerBound, closed.width.lowerBound + 300)
        // Hidden with the preview: the window is the sidebar alone.
        let hidden = WindowLayout.limits(previewShown: false, fittedHeight: 600, maxContent: screen, inspectorWidth: 300)
        XCTAssertEqual(hidden.width, WindowLayout.sidebarWidth...WindowLayout.sidebarWidth)
    }

    func testTargetWidthGrowsToFitThePanelWithinTheScreen() {
        let current = CGSize(width: 1000, height: 600)
        let target = WindowLayout.targetSize(previewShown: true, current: current, contentHeight: 600,
                                             requestedWidth: 1300, maxContent: screen, inspectorWidth: 300)
        XCTAssertEqual(target.width, 1300)
        let small = WindowLayout.targetSize(previewShown: true, current: current, contentHeight: 600,
                                            requestedWidth: 700, maxContent: screen, inspectorWidth: 300)
        XCTAssertEqual(small.width, WindowLayout.sidebarWidth + WindowLayout.previewMinWidth + 300)
        let narrowScreen = WindowLayout.targetSize(previewShown: true, current: current, contentHeight: 600,
                                                   requestedWidth: 2000, maxContent: CGSize(width: 1000, height: 800),
                                                   inspectorWidth: 300)
        XCTAssertEqual(narrowScreen.width, 1000)
    }

    func testPanelWidthIsClamped() {
        XCTAssertEqual(WindowLayout.clampedInspectorWidth(100), WindowLayout.inspectorMinWidth)
        XCTAssertEqual(WindowLayout.clampedInspectorWidth(900), WindowLayout.inspectorMaxWidth)
        XCTAssertEqual(WindowLayout.clampedInspectorWidth(.nan), WindowLayout.defaultInspectorWidth)
        // The preview keeps its minimum: a 1100 pt window leaves 320 pt for the panel.
        XCTAssertEqual(WindowLayout.clampedInspectorWidth(500, windowWidth: 1100), 320)
        XCTAssertEqual(WindowLayout.clampedInspectorWidth(500, windowWidth: 800), WindowLayout.inspectorMinWidth)
    }
}
