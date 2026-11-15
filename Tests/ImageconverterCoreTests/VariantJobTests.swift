import XCTest
@testable import ImageconverterCore

/// Jobs with extra outputs: the ledger records every output, so none of them is taken as a new input.
final class VariantJobTests: XCTestCase {
    private var root: URL!
    private var input: URL!
    private var store: JobStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: WatchFilter.canonicalPath(try TestImages.tempDir()), isDirectory: true)
        input = root.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        store = JobStore(directory: root.appendingPathComponent("jobs", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ job: Job) async -> JobRunResult {
        await JobRunner.run(job, store: store, trash: { _ in }, now: { Date().addingTimeInterval(10) })
    }

    func testLedgerRecordsEveryOutputAndASecondRunProcessesNothing() async throws {
        for name in ["a.jpg", "b.jpg"] {
            try TestImages.write(TestImages.make(width: 60, height: 30), to: input.appendingPathComponent(name),
                                 type: .jpeg)
        }
        let pipeline = Pipeline(output: OutputSettings(format: .png), extraOutputs: [
            OutputVariant(name: "Thumb", settings: OutputSettings(format: .jpeg), resize: .longestEdge(20),
                          nameSuffix: "_thumb"),
            OutputVariant(name: "Web", settings: OutputSettings(format: .heic), resize: nil, nameSuffix: "_web"),
        ])
        let job = Job(name: "Thumbs", pipeline: pipeline, inputs: [input], output: .sameFolder(suffix: "_new"),
                      trigger: .watch)
        let first = await run(job)
        XCTAssertEqual(first.batch.failures, [])
        XCTAssertEqual(first.batch.written.map(\.lastPathComponent).sorted(),
                       ["a.png", "a_thumb.jpg", "a_web.heic", "b.png", "b_thumb.jpg", "b_web.heic"])
        XCTAssertEqual(first.report.summary.succeeded, 2)
        let ledger = try store.loadLedger(id: job.id)
        for url in first.batch.written {
            let fingerprint = try XCTUnwrap(FileFingerprint.of(url))
            XCTAssertTrue(ledger.isSettled(fingerprint), url.lastPathComponent)
        }

        let second = await run(job)
        XCTAssertEqual(second.batch.order, [])
        XCTAssertEqual(second.batch.written, [])
        XCTAssertEqual(second.unchanged, 8)
    }

    func testAJobNamesExtraOutputsItsPipelineLeftOut() async throws {
        try TestImages.write(TestImages.make(width: 60, height: 30), to: input.appendingPathComponent("a.jpg"),
                             type: .jpeg)
        let json = #"{"output":{"format":"png"},"extraOutputs":[{"name":"Blank","nameSuffix":""}]}"#
        let pipeline = try JSONDecoder().decode(Pipeline.self, from: Data(json.utf8))
        let job = Job(name: "Old", pipeline: pipeline, inputs: [input], output: .sameFolder(suffix: "_new"),
                      trigger: .watch)
        let result = await run(job)
        XCTAssertEqual(result.batch.convertedCount, 1)
        XCTAssertTrue(result.problem?.contains("Extra output “Blank” was left out") == true, result.problem ?? "nil")
        // An empty check (nothing to do) says nothing, so the history isn't filled with it.
        let again = await run(job)
        XCTAssertNil(again.problem)
    }
}
