import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// The histogram panel fits the preview stage: full size on a tall stage, smaller and compact on a short one.
final class HistogramLayoutTests: XCTestCase {
    func testTallStageGetsTheFullChart() {
        let layout = HistogramLayout(stageHeight: 700)
        XCTAssertEqual(layout.chartSize, CGSize(width: 240, height: 120))
        XCTAssertFalse(layout.compact)
    }

    func testShortStageKeepsThePanelUnderTwoFifths() {
        for stage in stride(from: 300.0, through: 520, by: 20) {
            let layout = HistogramLayout(stageHeight: stage)
            XCTAssertLessThanOrEqual(layout.panelHeight, stage * 0.4 + 0.5, "stage \(stage)")
            XCTAssertEqual(layout.chartSize.width, 240)
        }
    }

    func testVeryShortStageIsCompactWithTheSmallestChart() {
        let layout = HistogramLayout(stageHeight: 200)
        XCTAssertTrue(layout.compact)
        XCTAssertEqual(layout.chartSize, CGSize(width: 240, height: 48))
        XCTAssertLessThan(layout.panelHeight, HistogramLayout(stageHeight: 299).panelHeight + 1)
    }

    func testUnmeasuredStageIsFullSize() {
        XCTAssertEqual(HistogramLayout(stageHeight: 0).chartSize, CGSize(width: 240, height: 120))
    }
}
