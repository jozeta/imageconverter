import XCTest
@testable import ImageconverterCore

final class ProcessingReportTests: XCTestCase {
    private func entry(_ name: String, _ input: Int, _ output: Int) -> BatchResultEntry {
        BatchResultEntry(source: URL(fileURLWithPath: "/in/\(name)"), destination: URL(fileURLWithPath: "/out/\(name)"),
                         inputBytes: input, outputBytes: output)
    }

    func testSummaryMaths() {
        var batch = BatchReport(entries: [entry("a.jpg", 1000, 250), entry("b.jpg", 1000, 750)])
        batch.failures = [BatchFailure(source: URL(fileURLWithPath: "/in/c.jpg"), reason: "Unreadable", inputBytes: 77)]
        let report = ProcessingReport(batch: batch, total: 3, outputMode: "newFolder")
        let summary = report.summary
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.inputBytes, 2000)
        XCTAssertEqual(summary.outputBytes, 1000)
        XCTAssertEqual(summary.savedBytes, 1000)
        XCTAssertEqual(summary.overallRatio, 0.5)
        XCTAssertEqual(try XCTUnwrap(summary.averageRatio), 0.5, accuracy: 1e-9)
        XCTAssertEqual(report.entries.count, 3)
        XCTAssertEqual(report.entries[2].status, .failed)
        XCTAssertEqual(report.entries[2].inputBytes, 77)
        XCTAssertEqual(report.entries[2].note, "Unreadable")
    }

    func testCancelledCountsUnprocessed() {
        let batch = BatchReport(cancelled: true, entries: [entry("a.jpg", 10, 5)])
        XCTAssertEqual(ProcessingReport(batch: batch, total: 4, outputMode: "x").summary.cancelled, 3)
    }

    func testUnknownSizesAreLeftOutOfTotals() {
        let batch = BatchReport(entries: [entry("a.jpg", 1000, 500),
                                          BatchResultEntry(source: URL(fileURLWithPath: "/in/b.jpg"),
                                                           destination: URL(fileURLWithPath: "/out/b.jpg"),
                                                           inputBytes: nil, outputBytes: 900)])
        let summary = ProcessingReport(batch: batch, total: 2, outputMode: "x").summary
        XCTAssertEqual(summary.inputBytes, 1000)
        XCTAssertEqual(summary.outputBytes, 500)
    }

    func testSamePhrase() {
        XCTAssertEqual(SizeFormat.savedPhrase(input: 500, output: 500), "same size")
    }

    func testEmptyBatchHasNoRatio() {
        let summary = ProcessingReport(batch: BatchReport(), total: 0, outputMode: "x").summary
        XCTAssertNil(summary.averageRatio)
        XCTAssertNil(summary.overallRatio)
    }

    func testPercentFormat() {
        XCTAssertEqual(SizeFormat.percentChange(from: 1000, to: 260), "\u{2212}74 %")
        XCTAssertEqual(SizeFormat.percentChange(from: 1000, to: 1120), "+12 %")
        XCTAssertEqual(SizeFormat.percentChange(from: 1000, to: 1000), "0 %")
        XCTAssertNil(SizeFormat.percentChange(from: 0, to: 5))
        XCTAssertTrue(SizeFormat.savedPhrase(input: 1000, output: 400)?.hasPrefix("saved") ?? false)
        XCTAssertTrue(SizeFormat.savedPhrase(input: 1000, output: 1200)?.hasPrefix("grew by") ?? false)
    }
}
