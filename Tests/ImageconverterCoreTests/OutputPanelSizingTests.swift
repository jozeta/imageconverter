import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// The Output panel's grab handle: drag maths, where a drag settles, the stored height and the collapsed summary.
final class OutputPanelSizingTests: XCTestCase {
    private let collapsed: CGFloat = 40
    private let full: CGFloat = 300

    func testDragIsClampedBetweenCollapsedAndFull() {
        // Dragging up (negative translation) makes the panel taller.
        XCTAssertEqual(OutputPanelSizing.dragged(from: 200, translation: -50, collapsed: collapsed, full: full), 250)
        XCTAssertEqual(OutputPanelSizing.dragged(from: 200, translation: -500, collapsed: collapsed, full: full), full)
        XCTAssertEqual(OutputPanelSizing.dragged(from: 200, translation: 500, collapsed: collapsed, full: full), collapsed)
        // Content shorter than the collapsed panel (not measured yet): never an inverted range.
        XCTAssertEqual(OutputPanelSizing.dragged(from: 10, translation: 0, collapsed: 40, full: 20), 40)
    }

    func testSettlesCollapsedFullOrInBetween() {
        let settle = { (height: CGFloat) in OutputPanelSizing.settled(height, collapsed: self.collapsed, full: self.full) }
        XCTAssertEqual(settle(collapsed), OutputPanelSizing.State(collapsed: true, height: nil))
        XCTAssertEqual(settle(collapsed + 3), OutputPanelSizing.State(collapsed: true, height: nil), "snaps shut")
        XCTAssertEqual(settle(collapsed + OutputPanelSizing.collapseSnap), OutputPanelSizing.State(collapsed: true, height: nil),
                       "no sliver of the open panel is left")
        XCTAssertEqual(settle(collapsed + OutputPanelSizing.collapseSnap + 1),
                       OutputPanelSizing.State(collapsed: false, height: collapsed + OutputPanelSizing.collapseSnap + 1))
        XCTAssertEqual(settle(full - 2), OutputPanelSizing.State(collapsed: false, height: nil), "snaps to full")
        XCTAssertEqual(settle(150), OutputPanelSizing.State(collapsed: false, height: 150))
    }

    func testShownHeight() {
        let shown = { (state: OutputPanelSizing.State) in
            OutputPanelSizing.shownHeight(state, collapsed: self.collapsed, full: self.full)
        }
        XCTAssertNil(shown(.init(collapsed: false, height: nil)), "full: natural height")
        XCTAssertNil(shown(.init(collapsed: true, height: 150)), "collapsed: the summary's own height")
        XCTAssertEqual(shown(.init(collapsed: false, height: 150)), 150)
        XCTAssertNil(shown(.init(collapsed: false, height: 900)), "content got shorter: full again")
        XCTAssertEqual(shown(.init(collapsed: false, height: 10)), collapsed)
    }

    func testStoredHeightIsValidated() {
        XCTAssertNil(OutputPanelSizing.storedHeight(nil))
        XCTAssertNil(OutputPanelSizing.storedHeight(0))
        XCTAssertNil(OutputPanelSizing.storedHeight(-5))
        XCTAssertNil(OutputPanelSizing.storedHeight(.nan))
        XCTAssertNil(OutputPanelSizing.storedHeight(1_000_000))
        XCTAssertEqual(OutputPanelSizing.storedHeight(180), 180)
    }

    func testKeyboardStep() {
        XCTAssertEqual(OutputPanelSizing.stepped(from: 150, by: 1, collapsed: collapsed, full: full),
                       OutputPanelSizing.State(collapsed: false, height: 150 + OutputPanelSizing.keyStep))
        XCTAssertEqual(OutputPanelSizing.stepped(from: collapsed + 10, by: -1, collapsed: collapsed, full: full),
                       OutputPanelSizing.State(collapsed: true, height: nil))
        XCTAssertEqual(OutputPanelSizing.stepped(from: full, by: 1, collapsed: collapsed, full: full),
                       OutputPanelSizing.State(collapsed: false, height: nil))
    }

    private func parts(steps: CGFloat, output: CGFloat) -> WindowLayout.SidebarParts {
        WindowLayout.SidebarParts(top: 200, steps: steps, output: output, bottom: 40, chrome: 40, stepsGap: 4, spacing: 12)
    }

    func testReleasedPinKeepsTheHeightWhileTheStepsScroll() {
        // Output grew under a pinned window: the content (steps 300) no longer fits in 600, so 600 is kept.
        let grown = parts(steps: 300, output: 200)
        XCTAssertGreaterThan(grown.expanded, 600)
        XCTAssertEqual(WindowLayout.releasedRememberedHeight(pinned: 600, parts: grown, rememberedBefore: nil,
                                                             maxContent: CGSize(width: 2000, height: 1200)), 600)
    }

    func testReleasedPinLeavesNoGap() {
        // Output collapsed under a pinned window: the content is shorter than the window, so the window fits it
        // again (nothing remembered) instead of keeping an empty gap above Output.
        let collapsed = parts(steps: 100, output: 40)
        XCTAssertLessThan(collapsed.expanded, 600)
        let screen = CGSize(width: 2000, height: 1200)
        XCTAssertNil(WindowLayout.releasedRememberedHeight(pinned: 600, parts: collapsed, rememberedBefore: nil,
                                                           maxContent: screen))
        XCTAssertEqual(WindowLayout.releasedRememberedHeight(pinned: 600, parts: collapsed, rememberedBefore: 800,
                                                             maxContent: screen), 800, "the user's own height comes back")
        // The pin is clamped to what the parts allow (the screen).
        XCTAssertEqual(WindowLayout.releasedRememberedHeight(pinned: 5000, parts: parts(steps: 3000, output: 200),
                                                             rememberedBefore: nil, maxContent: screen), 1200)
    }

    func testSummaryLine() {
        var output = OutputSettings(format: .jpeg, quality: 0.8)
        XCTAssertEqual(OutputSummary.line(output, saveTo: .newFolder, folderName: "Converted", suffix: "_new"),
                       "JPEG · 80 % · Converted")
        output.compression = .targetSize(bytes: 500_000)
        XCTAssertEqual(OutputSummary.line(output, saveTo: .sameFolder, folderName: nil, suffix: "_new"),
                       "JPEG · target \(SizeFormat.bytes(500_000)) · same folder (_new)")
        output.compression = .maxSize(bytes: 2_000_000)
        XCTAssertEqual(OutputSummary.line(output, saveTo: .overwrite, folderName: nil, suffix: ""),
                       "JPEG · max \(SizeFormat.bytes(2_000_000)) · overwrite originals")
        output.compression = .smart
        XCTAssertEqual(OutputSummary.line(output, saveTo: .newFolder, folderName: nil, suffix: ""),
                       "JPEG · smart · no folder chosen")
        XCTAssertEqual(OutputSummary.line(OutputSettings(format: .png), saveTo: .sameFolder, folderName: nil, suffix: ""),
                       "PNG · same folder", "no quality for PNG; no suffix shown when empty")
        XCTAssertEqual(OutputSummary.line(OutputSettings(format: .png), saveTo: .overwrite, folderName: nil, suffix: "",
                                          extraOutputs: 2),
                       "PNG · overwrite originals · +2 outputs")
    }

    func testMainCardLineLeavesOutTheExtraOutputs() {
        let output = OutputSettings(format: .jpeg, quality: 0.8)
        XCTAssertEqual(OutputSummary.cardLine(output, saveTo: .newFolder, folderName: "Converted", suffix: "_new"),
                       "JPEG · 80 % · Converted")
        XCTAssertEqual(OutputSummary.cardLine(OutputSettings(format: .png), saveTo: .overwrite, folderName: nil,
                                              suffix: ""),
                       "PNG · overwrite originals")
    }

    func testSeveralPanelsScrollInsideAScreenShare() {
        XCTAssertEqual(OutputPanelSizing.maxOpenHeight(screenHeight: 1000), 600)
        XCTAssertEqual(OutputPanelSizing.maxOpenHeight(screenHeight: 300), OutputPanelSizing.minOpenCap)
        XCTAssertEqual(OutputPanelSizing.maxOpenHeight(screenHeight: 0), .infinity)
        XCTAssertEqual(OutputPanelSizing.reachable(full: 900, cap: 600), 600)
        XCTAssertEqual(OutputPanelSizing.reachable(full: 400, cap: 600), 400)
    }
}
