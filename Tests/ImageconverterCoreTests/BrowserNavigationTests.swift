import XCTest
@testable import ImageconverterCore

final class BrowserNavigationTests: XCTestCase {
    func testColumnsFitTheWidth() {
        XCTAssertEqual(BrowserNavigation.columns(width: 0, cell: 72, spacing: 8), 1)
        XCTAssertEqual(BrowserNavigation.columns(width: 72, cell: 72, spacing: 8), 1)
        XCTAssertEqual(BrowserNavigation.columns(width: 151, cell: 72, spacing: 8), 1)
        XCTAssertEqual(BrowserNavigation.columns(width: 152, cell: 72, spacing: 8), 2)
        XCTAssertEqual(BrowserNavigation.columns(width: .nan, cell: 72, spacing: 8), 1)
    }

    func testArrowsMoveInTwoDimensions() {
        // 10 items in 4 columns: rows 0-3, 4-7, 8-9.
        XCTAssertEqual(BrowserNavigation.move(from: 5, direction: .right, columns: 4, count: 10), 6)
        XCTAssertEqual(BrowserNavigation.move(from: 5, direction: .left, columns: 4, count: 10), 4)
        XCTAssertEqual(BrowserNavigation.move(from: 5, direction: .above, columns: 4, count: 10), 1)
        XCTAssertEqual(BrowserNavigation.move(from: 5, direction: .below, columns: 4, count: 10), 9)
    }

    func testArrowsStopAtTheEdges() {
        XCTAssertEqual(BrowserNavigation.move(from: 0, direction: .left, columns: 4, count: 10), 0)
        XCTAssertEqual(BrowserNavigation.move(from: 9, direction: .right, columns: 4, count: 10), 9)
        XCTAssertEqual(BrowserNavigation.move(from: 2, direction: .above, columns: 4, count: 10), 2)
        // Down from a column the last row doesn't reach goes to the last item.
        XCTAssertEqual(BrowserNavigation.move(from: 7, direction: .below, columns: 4, count: 10), 9)
        XCTAssertEqual(BrowserNavigation.move(from: 9, direction: .below, columns: 4, count: 10), 9)
    }

    func testEmptyAndOutOfRange() {
        XCTAssertNil(BrowserNavigation.move(from: 0, direction: .below, columns: 4, count: 0))
        XCTAssertEqual(BrowserNavigation.move(from: 42, direction: .left, columns: 4, count: 10), 8)
        XCTAssertEqual(BrowserNavigation.move(from: 3, direction: .below, columns: 0, count: 10), 4)
    }

    func testDifferenceSummary() {
        let identical = ImageDifference.Stats(meanAbsError: 0, maxError: 0, psnr: .infinity)
        XCTAssertEqual(CompareText.differenceSummary(identical), "Identical: no pixel changed")
        let lossy = ImageDifference.Stats(meanAbsError: 1.234, maxError: 37, psnr: 41.26)
        XCTAssertEqual(CompareText.differenceSummary(lossy), "PSNR 41.3 dB · mean error 1.23 · max 37 (shown ×4)")
        XCTAssertEqual(CompareText.differenceSummary(identical, region: true), "Identical: no pixel changed · visible region")
        XCTAssertEqual(CompareText.differenceSummary(lossy, region: true, scaled: true),
                       "PSNR 41.3 dB · mean error 1.23 · max 37 (shown ×4) · visible region, scaled down")
    }

    func testSaving() {
        XCTAssertEqual(CompareText.saving(original: 1000, output: 250), "−75 %")
        XCTAssertEqual(CompareText.saving(original: 1000, output: 1200), "+20 %")
        XCTAssertNil(CompareText.saving(original: nil, output: 10))
    }
}
