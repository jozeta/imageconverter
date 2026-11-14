import XCTest
@testable import ImageconverterCore

final class ReportOutputsTests: XCTestCase {
    func testExistingOutputsKeepsOnlyWrittenFilesThatExist() {
        let now = Date()
        let summary = RunSummary(startedAt: now, finishedAt: now, outputMode: "sameFolder", total: 4, succeeded: 2, failed: 1,
                                 skipped: 1, inputBytes: 10, outputBytes: 5)
        let entries = [
            ReportEntry(source: "/a.jpg", destination: "/out/a.jpg", status: .succeeded, inputBytes: 5, outputBytes: 2),
            ReportEntry(source: "/b.jpg", destination: "/out/b.jpg", status: .succeeded, inputBytes: 5, outputBytes: 3),
            ReportEntry(source: "/c.jpg", status: .failed, inputBytes: 1),
            ReportEntry(source: "/d.jpg", destination: "/out/d.jpg", status: .skipped, inputBytes: 1)
        ]
        let report = ProcessingReport(summary: summary, entries: entries)
        let found = report.existingOutputs { $0 == "/out/a.jpg" || $0 == "/out/d.jpg" }
        XCTAssertEqual(found.map(\.path), ["/out/a.jpg"])
    }
}
