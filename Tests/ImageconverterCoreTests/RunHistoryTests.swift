import XCTest
@testable import ImageconverterCore

final class RunHistoryTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func report(finished: Double, job: String? = nil, entries: Int = 1) -> ProcessingReport {
        let summary = RunSummary(startedAt: Date(timeIntervalSince1970: finished - 1),
                                 finishedAt: Date(timeIntervalSince1970: finished), jobName: job, outputMode: "newFolder",
                                 total: entries, succeeded: entries, failed: 0, inputBytes: 10, outputBytes: 5)
        return ProcessingReport(summary: summary, entries: (0..<entries).map {
            ReportEntry(source: "/in/\($0).jpg", status: .succeeded, inputBytes: 10, outputBytes: 5)
        })
    }

    func testJSONRoundTrip() throws {
        let original = report(finished: 1000, job: "Drop")
        let data = ReportExporter.json(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct Shape: Decodable { let summary: RunSummary; let entries: [ReportEntry] }
        let decoded = try decoder.decode(Shape.self, from: data)
        XCTAssertEqual(decoded.summary, original.summary)
        XCTAssertEqual(decoded.entries, original.entries)
        XCTAssertTrue((String(data: data, encoding: .utf8) ?? "").contains("1970-01-01T00:16:40Z"))
    }

    func testHistoryKeeps100AndRejectsGarbage() throws {
        let history = RunHistory.shared(directory: directory)
        for index in 0..<103 { try history.save(report(finished: Double(1000 + index))) }
        let summaries = history.summaries()
        XCTAssertEqual(summaries.count, 100)
        XCTAssertEqual(summaries.first?.finishedAt, Date(timeIntervalSince1970: 1102))
        XCTAssertEqual(summaries.last?.finishedAt, Date(timeIntervalSince1970: 1003))

        let id = UUID()
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("notes.json"))
        // A valid record under another run's file name is refused.
        let valid = try Data(contentsOf: directory.appendingPathComponent("\(summaries[0].id.uuidString).json"))
        try valid.write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        // An oversized file and a symlink are refused.
        try Data(count: RunHistory.maxFileSize + 1).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("\(UUID().uuidString).json"),
            withDestinationURL: directory.appendingPathComponent("\(summaries[0].id.uuidString).json"))
        XCTAssertEqual(history.summaries().count, 100)
        XCTAssertNil(history.record(id: id))
    }

    func testEntriesCappedAndJobFilter() throws {
        let history = RunHistory.shared(directory: directory)
        let big = report(finished: 10, job: "A", entries: RunHistory.maxEntries + 5)
        try history.save(big)
        try history.save(report(finished: 20, job: "B"))
        let stored = try XCTUnwrap(history.record(id: big.summary.id))
        XCTAssertEqual(stored.entries.count, RunHistory.maxEntries)
        XCTAssertTrue(stored.entriesTruncated)
        XCTAssertEqual(history.summaries(jobName: "A").map(\.id), [big.summary.id])
        XCTAssertEqual(history.summaries(jobName: "B").count, 1)
        history.delete(id: big.summary.id)
        XCTAssertEqual(history.summaries().count, 1)
    }

    func testListingReadsSummariesOnly() throws {
        let history = RunHistory.shared(directory: directory)
        let first = report(finished: 10, entries: 3)
        try history.save(first)
        try history.save(report(finished: 20))
        // Corrupt the full record: listing must not open it, loading it must fail.
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("\(first.summary.id.uuidString).json"))
        XCTAssertEqual(history.summaries().count, 2)
        XCTAssertNil(history.record(id: first.summary.id))
    }

    func testMissingSummaryIsRebuiltFromFullRecord() throws {
        let history = RunHistory.shared(directory: directory)
        let run = report(finished: 10)
        try history.save(run)
        let summaryFile = directory.appendingPathComponent("\(run.summary.id.uuidString).summary.json")
        try FileManager.default.removeItem(at: summaryFile)
        XCTAssertEqual(history.summaries().map(\.id), [run.summary.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryFile.path))
        history.delete(id: run.summary.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: summaryFile.path))
    }

    func testSharedInstancePerDirectory() {
        let detour = directory.appendingPathComponent("../\(directory.lastPathComponent)")
        XCTAssertTrue(RunHistory.shared(directory: directory) === RunHistory.shared(directory: detour))
        XCTAssertTrue(ErrorLog.shared(directory: directory) === ErrorLog.shared(directory: directory))
        XCTAssertFalse(RunHistory.shared(directory: directory) === RunHistory.shared(directory: directory.appendingPathComponent("x")))
    }
}
