import CoreGraphics
import ImageIO
import XCTest
@testable import ImageconverterCore

final class JobRunnerTests: XCTestCase {
    private var root: URL!
    private var input: URL!
    private var output: URL!
    private var store: JobStore!
    private let noTrash: Trasher = { _ in }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: WatchFilter.canonicalPath(try TestImages.tempDir()), isDirectory: true)
        input = root.appendingPathComponent("Drop", isDirectory: true)
        output = input.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        store = JobStore(directory: root.appendingPathComponent("jobs", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var gps: [String: Any] {
        [kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E"
        ] as [String: Any]]
    }

    @discardableResult
    private func drop(_ name: String, width: Int = 40, height: Int = 20, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? input).appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: .jpeg, properties: gps)
        return url
    }

    private func job(_ pipeline: Pipeline = Pipeline(output: OutputSettings(format: .png)), presetID: UUID? = nil,
                     mode: OutputMode? = nil, report: ReportFormat? = nil) -> Job {
        Job(name: "Drop job", pipeline: pipeline, presetID: presetID, inputs: [input],
            output: mode ?? .newFolder(output), trigger: .watch, report: report)
    }

    /// Runs as if 10 s had passed, so the files just written count as settled (see `testFilesStillBeingWrittenWait`).
    private func run(_ job: Job, files: [URL]? = nil, presets: PresetStore? = nil) async -> JobRunResult {
        await JobRunner.run(job, files: files, store: store, presetStore: presets, trash: noTrash,
                            now: { Date().addingTimeInterval(10) })
    }

    func testLedgerSkipsUnchangedAndRedoesChanged() async throws {
        try drop("a.jpg")
        let changed = try drop("b.jpg")
        let job = job()
        let first = await run(job)
        XCTAssertEqual(first.batch.written.count, 2)
        XCTAssertEqual(first.unchanged, 0)

        let second = await run(job)
        XCTAssertEqual(second.batch.written.count, 0)
        XCTAssertEqual(second.unchanged, 2)
        XCTAssertEqual(second.report.summary.unchanged, 2)
        XCTAssertEqual(second.report.summary.skipped, 0)

        try TestImages.write(TestImages.make(width: 50, height: 20), to: changed, type: .jpeg)
        let third = await run(job)
        XCTAssertEqual(third.batch.order.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertEqual(third.unchanged, 1)
    }

    /// Final review I4: a file another run in this process holds is skipped ("Busy in another run") and stays a
    /// candidate, so the next run processes it.
    func testFilesHeldByAnotherRunAreSkippedAndNotRecorded() async throws {
        let held = try drop("held.jpg")
        try drop("free.jpg")
        let key = InputItem(source: held, relativeDirectory: "").pathKey
        let (claimed, _) = ActiveSources.shared.claim([key])
        XCTAssertEqual(claimed, [key])
        let job = job()
        let busyRun = await run(job)
        ActiveSources.shared.release(claimed)
        XCTAssertEqual(busyRun.batch.written.map(\.lastPathComponent), ["free.png"])
        XCTAssertEqual(busyRun.batch.skipped.map(\.reason), [ActiveSources.busyReason])
        XCTAssertTrue(busyRun.report.entries.contains { $0.status == .skipped && $0.note == ActiveSources.busyReason })
        let next = await run(job)
        XCTAssertEqual(next.batch.written.map(\.lastPathComponent), ["held.png"], "not recorded as processed")
    }

    func testFailedFilesAreRetriedThreeTimesThenGivenUp() async throws {
        let bad = input.appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: bad)
        let job = job(report: .csv)
        for attempt in 1...3 {
            let result = await run(job)
            XCTAssertEqual(result.batch.failures.map(\.source.lastPathComponent), ["bad.jpg"], "attempt \(attempt)")
            let note = try XCTUnwrap(result.report.entries.first?.note)
            XCTAssertEqual(note.hasPrefix("Gave up after 3 attempts"), attempt == 3, note)
        }
        let fourth = await run(job)
        XCTAssertEqual(fourth.batch.order, [], "given up: not tried again while unchanged")
        XCTAssertEqual(fourth.unchanged, 1)

        try Data("still not an image".utf8).write(to: bad)
        let changed = await run(job)
        XCTAssertEqual(changed.batch.failures.count, 1, "a changed file is tried again")
        XCTAssertFalse(changed.report.entries.first?.note?.hasPrefix("Gave up") ?? true)
    }

    func testFilesStillBeingWrittenWait() async throws {
        try drop("fresh.jpg")
        let job = job()
        let early = await JobRunner.run(job, store: store, trash: noTrash, now: { Date() })
        XCTAssertEqual(early.batch.order, [], "changed less than 2 s ago")
        XCTAssertEqual(early.waiting, 1)
        XCTAssertEqual(try store.loadLedger(id: job.id).count, 0, "waiting files are not recorded")
        let later = await JobRunner.run(job, store: store, trash: noTrash, now: { Date().addingTimeInterval(3) })
        XCTAssertEqual(later.batch.written.count, 1)
        XCTAssertEqual(later.waiting, 0)
    }

    func testUnreadableFilesWait() async throws {
        let locked = try drop("locked.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let result = await run(job())
        XCTAssertEqual(result.batch.order, [])
        XCTAssertEqual(result.waiting, 1)
    }

    func testOwnOutputsAreNeverInputs() async throws {
        try drop("a.jpg")
        let job = job(mode: .sameFolder(suffix: "_new"))
        let first = await run(job)
        XCTAssertEqual(first.batch.written.map(\.lastPathComponent), ["a.png"])
        // The written a.png sits in the input folder: the next run must leave it alone.
        let second = await run(job)
        XCTAssertEqual(second.batch.order, [])
        XCTAssertEqual(second.unchanged, 2)
    }

    func testOnlyGivenFilesInsideTheJobRun() async throws {
        let inside = try drop("a.jpg")
        try drop("b.jpg")
        let elsewhere = try drop("c.jpg", in: root)
        let result = await run(job(), files: [inside, elsewhere, output.appendingPathComponent("x.jpg")])
        XCTAssertEqual(result.batch.order.map(\.lastPathComponent), ["a.jpg"])
    }

    func testPresetLinkedJobUsesCurrentPreset() async throws {
        let presets = PresetStore(directory: root.appendingPathComponent("presets", isDirectory: true))
        var preset = Preset(name: "Linked", pipeline: Pipeline(output: OutputSettings(format: .png)))
        try presets.save(preset)
        try drop("a.jpg")
        let job = job(Pipeline(output: OutputSettings(format: .tiff)), presetID: preset.id)
        // The preset changes after the job was made: the run uses it as it is now.
        preset.pipeline.output = OutputSettings(format: .jpeg)
        try presets.save(preset)
        let result = await run(job, presets: presets)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.batch.written.map(\.pathExtension), ["jpg"])

        try presets.delete(id: preset.id)
        try drop("b.jpg")
        let orphan = await run(job, presets: presets)
        XCTAssertEqual(orphan.problem, "The job's preset no longer exists.")
        XCTAssertEqual(orphan.batch.order, [])
    }

    func testUnreadableLedgerStopsTheRun() async throws {
        try drop("a.jpg")
        let job = job()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.ledgerURL(for: job.id))
        let result = await run(job)
        XCTAssertNotNil(result.problem)
        XCTAssertEqual(result.batch.order, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testNoReportWhenNothingWasProcessed() async throws {
        let result = await run(job(report: .csv))
        XCTAssertNil(result.reportFile)
        XCTAssertNil(result.problem)
    }

    /// The example job from the spec: a watched drop folder with the Web export preset (≤ 2048 px, no GPS)
    /// and a CSV report next to the outputs.
    func testExampleJobEndToEnd() async throws {
        let job = try savedExampleJob()
        let delivered = expectation(description: "watcher saw both files")
        let seen = LockedLog<URL>()
        let watcher = FolderWatcher(folders: job.inputs, recursive: job.recursive, excluded: job.excludedFolders,
                                    stableFor: 0.5, pollInterval: 0.2) { urls in
            urls.forEach(seen.append)
            if Set(seen.values.map(\.lastPathComponent)).isSuperset(of: ["one.jpg", "two.jpg"]) { delivered.fulfill() }
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)
        try dropExampleFiles()
        guard await XCTWaiter.fulfillment(of: [delivered], timeout: 20) == .completed else {
            throw XCTSkip("FSEvents delivered no event in this environment (testExampleJobScheduledRun covers the job)")
        }
        try await assertExampleRun(job, files: seen.values)
    }

    /// The same job run by a schedule or "Run now": a scan of the folder instead of watcher events.
    func testExampleJobScheduledRun() async throws {
        let job = try savedExampleJob()
        try dropExampleFiles()
        try await assertExampleRun(job, files: nil)
    }

    private func savedExampleJob() throws -> Job {
        let webExport = try XCTUnwrap(PresetStore.builtIns.first { $0.name == "Web export" })
        try store.save(job(presetID: webExport.id, report: .csv))
        return try XCTUnwrap(store.load().jobs.first)
    }

    private func dropExampleFiles() throws {
        try drop("one.jpg", width: 3000, height: 1000)
        try drop("two.jpg", width: 1200, height: 2600)
    }

    private func assertExampleRun(_ job: Job, files: [URL]?) async throws {
        let result = await run(job, files: files)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.batch.failures, [])
        XCTAssertEqual(result.batch.written.map(\.lastPathComponent).sorted(), ["one.jpg", "two.jpg"])
        for url in result.batch.written {
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "out")
            let properties = try TestImages.properties(of: try Data(contentsOf: url))
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String], url.lastPathComponent)
            let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth as String] as? Int)
            let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight as String] as? Int)
            XCTAssertLessThanOrEqual(max(width, height), 2048)
        }
        let reportFile = try XCTUnwrap(result.reportFile)
        XCTAssertEqual(reportFile.deletingLastPathComponent().standardizedFileURL, output.standardizedFileURL)
        XCTAssertTrue(reportFile.lastPathComponent.hasPrefix("imageconverter-report-"))
        let csv = try String(contentsOf: reportFile)
        XCTAssertTrue(csv.hasPrefix(#""source","destination","status""#))
        XCTAssertTrue(csv.contains(#""TOTAL","","2 files: 2 succeeded, 0 failed, 0 skipped, 0 cancelled""#), csv)

        // The outputs and the report are inside the input folder, yet nothing is processed again.
        let again = await run(job)
        XCTAssertEqual(again.batch.order, [])
        XCTAssertNil(again.reportFile)
    }

    // MARK: Fix round 1

    func testASecondRunnerOfTheSameJobIsRefused() async throws {
        try drop("a.jpg")
        let job = job()
        // Another process (or the app) holds the job's lock.
        let held = try XCTUnwrap(JobLock.acquire(store.lockURL(for: job.id)))
        let refused = await run(job)
        XCTAssertEqual(refused.problem, JobLock.busyMessage)
        XCTAssertEqual(refused.batch.order, [])
        held.release()
        let done = await run(job)
        XCTAssertNil(done.problem)
        XCTAssertEqual(done.batch.written.count, 1)
        // Released at the end of the run.
        XCTAssertNotNil(JobLock.acquire(store.lockURL(for: job.id)))
    }

    func testRunResultsAreMergedIntoTheLedgerAsItIsNow() throws {
        let id = UUID()
        let old = FileFingerprint(path: "/x/old.jpg", size: 1, modified: 1)
        var start = ProcessedLedger()
        start.recordProcessed([old])
        try store.saveLedger(start, id: id)
        // Meanwhile someone resets the ledger; the run's result lands on the reset one.
        try store.resetLedger(id: id)
        let new = FileFingerprint(path: "/x/new.jpg", size: 2, modified: 2)
        try store.updateLedger(id: id) { $0.recordProcessed([new]) }
        let ledger = try store.loadLedger(id: id)
        XCTAssertTrue(ledger.isSettled(new))
        XCTAssertFalse(ledger.isSettled(old))
    }
}
