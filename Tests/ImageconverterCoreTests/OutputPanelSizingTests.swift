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
}
