import XCTest
@testable import ImageconverterCore

/// Extra outputs that fail are visible at run level: counts, report rows, toast and notification wording, jobs.
final class VariantFailureTests: XCTestCase {
    private var root: URL!
    private var out: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: WatchFilter.canonicalPath(try TestImages.tempDir()), isDirectory: true)
        out = root.appendingPathComponent("out", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root!).appendingPathComponent(name)
        try TestImages.write(TestImages.noise(width: 200, height: 100), to: url, type: .jpeg)
        return url
    }

    /// One output that can never fit (1 byte), one that works.
    private var pipeline: Pipeline {
        var broken = OutputVariant(name: "Tiny", resize: .longestEdge(50), nameSuffix: "_tiny")
        broken.settings.compression = .maxSize(bytes: 1)
        return Pipeline(output: OutputSettings(format: .jpeg), extraOutputs: [
            broken, OutputVariant(name: "Thumb", resize: .longestEdge(50), nameSuffix: "_thumb"),
        ])
    }

    private func items(_ urls: [URL]) -> [InputItem] { urls.map { InputItem(source: $0, relativeDirectory: "") } }

    func testFailedExtrasAreCountedAndReported() async throws {
        let first = try source("a.jpg")
        let second = try source("b.jpg")
        let batch = await BatchRunner.run(items([first, second]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(batch.failures, [])
        XCTAssertEqual(batch.convertedCount, 2)
        XCTAssertEqual(batch.extraFailures.map(\.name), ["Tiny", "Tiny"])
        XCTAssertEqual(batch.extraFailures.map(\.source), [first, second])
        XCTAssertEqual(batch.extraFailures.first?.destination?.lastPathComponent, "a_tiny.jpg")
        XCTAssertTrue(batch.extraFailures[0].message.hasPrefix("Extra output “Tiny” failed: "))

        let report = ProcessingReport(batch: batch, total: 2, outputMode: "newFolder")
        XCTAssertEqual(report.summary.succeeded, 2)
        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertEqual(report.summary.extraFailureCount, 2)
        XCTAssertEqual(report.entries.map { "\($0.name) \($0.status.rawValue)" },
                       ["a.jpg succeeded", "a.jpg + Thumb succeeded", "a.jpg + Tiny failed",
                        "b.jpg succeeded", "b.jpg + Thumb succeeded", "b.jpg + Tiny failed"])
        // The error log takes failed rows as they are: path and the message naming the output.
        let failed = report.entries.filter { $0.status == .failed }
        XCTAssertEqual(failed.first?.note, batch.extraFailures.first?.message)
        XCTAssertTrue(ReportExporter.counts(report.summary).hasSuffix(", 2 extra outputs failed"))
    }

    func testRunSummaryAndNotificationWording() async throws {
        let photo = try source("a.jpg")
        let batch = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        let (text, problems) = RunCountsText.runSummary(batch)
        XCTAssertTrue(text.hasPrefix("Converted 1 image · 1 extra output failed"), text)
        XCTAssertTrue(problems)
        XCTAssertEqual(AfterRunAction.notification(for: batch, summary: text).body, text)

        var cancelled = batch
        cancelled.cancelled = true
        XCTAssertEqual(AfterRunAction.notification(for: cancelled, summary: text).body,
                       "Run cancelled · converted 1 · 1 extra output failed")
        XCTAssertEqual(RunCountsText.extraFailures(3), "3 extra outputs failed")
    }

    func testCleanRunHasNoProblems() async throws {
        let photo = try source("a.jpg")
        let clean = Pipeline(output: OutputSettings(format: .jpeg),
                          extraOutputs: [OutputVariant(name: "Thumb", resize: .longestEdge(50), nameSuffix: "_thumb")])
        let batch = await BatchRunner.run(items([photo]), pipeline: clean, mode: .newFolder(out))
        let (text, problems) = RunCountsText.runSummary(batch)
        XCTAssertFalse(problems)
        XCTAssertFalse(text.contains("extra"), text)
        XCTAssertNil(ProcessingReport(batch: batch, total: 1, outputMode: "newFolder").summary.extraFailures)
    }

    func testSavedPhraseComparesPrimaryOutputsOnly() {
        var batch = BatchReport()
        batch.entries = [
            BatchResultEntry(source: URL(fileURLWithPath: "/a.jpg"), destination: URL(fileURLWithPath: "/o/a.jpg"),
                             inputBytes: 1000, outputBytes: 500),
        ]
        var big = BatchResultEntry(source: URL(fileURLWithPath: "/a.jpg"), destination: URL(fileURLWithPath: "/o/a.tif"),
                                   inputBytes: 1000, outputBytes: 9000)
        big.variant = "Full"
        batch.entries.append(big)
        XCTAssertEqual(batch.primaryOutputBytes, 500)
        let (text, _) = RunCountsText.runSummary(batch)
        XCTAssertTrue(text.hasSuffix("saved 500 bytes (50 %)"), text)
    }

    func testNoFreeNameCountsAsAFailedExtra() async throws {
        let photo = try source("a.jpg")
        let clean = Pipeline(output: OutputSettings(format: .jpeg),
                          extraOutputs: [OutputVariant(name: "Thumb", resize: .longestEdge(50), nameSuffix: "_thumb")])
        let (plans, _) = OutputPlanner.planVariants(
            [VariantTarget(variants: clean.extraOutputs)],
            primaries: [PlannedOutput(item: items([photo])[0], destination: out.appendingPathComponent("a.jpg"),
                                      replacesSource: false, trashesSource: false)],
            fileExists: { _ in true })
        XCTAssertEqual(plans, [[]])
        // Through the batch: every candidate name "exists" for the extra output only.
        var job = ResolvedPipeline(pipeline: clean)
        job.unplannedOutputs = ["Thumb"]
        job.pipeline.extraOutputs = []
        let plan = PlannedOutput(item: items([photo])[0], destination: out.appendingPathComponent("a.jpg"),
                                 replacesSource: false, trashesSource: false)
        let (result, _) = BatchRunner.process(plan, job: job, assets: .empty, maxPixels: 250_000_000,
                                              trash: { _ in })
        guard case .success(let written?) = result else { return XCTFail("not written") }
        XCTAssertEqual(written.extraFailures.map(\.name), ["Thumb"])
        XCTAssertEqual(written.extraFailures.first?.reason, OutputPlanner.noFreeNameReason)
    }

    func testAJobDoesNotRetryAFailedExtra() async throws {
        let input = root.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try _ = source("a.jpg", in: input)
        let store = JobStore(directory: root.appendingPathComponent("jobs", isDirectory: true))
        let job = Job(name: "Thumbs", pipeline: pipeline, inputs: [input], output: .newFolder(out), trigger: .watch)
        let first = await JobRunner.run(job, store: store, trash: { _ in }, now: { Date().addingTimeInterval(10) })
        XCTAssertEqual(first.batch.extraFailures.count, 1)
        XCTAssertEqual(first.report.summary.extraFailureCount, 1)
        let second = await JobRunner.run(job, store: store, trash: { _ in }, now: { Date().addingTimeInterval(10) })
        XCTAssertEqual(second.batch.order, [], "the image is done; its failed extra isn't tried again")
    }
}
