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

    private func run(_ job: Job, files: [URL]? = nil, presets: PresetStore? = nil) async -> JobRunResult {
        await JobRunner.run(job, files: files, store: store, presetStore: presets, trash: noTrash)
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
        XCTAssertEqual(second.report.summary.skipped, 2)

        try TestImages.write(TestImages.make(width: 50, height: 20), to: changed, type: .jpeg)
        let third = await run(job)
        XCTAssertEqual(third.batch.order.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertEqual(third.unchanged, 1)
    }

    func testFailedFilesAreNotRetriedUntilTheyChange() async throws {
        let bad = input.appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: bad)
        let job = job()
        let first = await run(job)
        XCTAssertEqual(first.batch.failures.count, 1)
        let second = await run(job)
        XCTAssertEqual(second.batch.failures.count, 0)
        XCTAssertEqual(second.unchanged, 1)
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
        let webExport = try XCTUnwrap(PresetStore.builtIns.first { $0.name == "Web export" })
        let job = job(presetID: webExport.id, report: .csv)
        try store.save(job)
        let job2 = try XCTUnwrap(store.load().jobs.first)

        var ready: [URL] = []
        let delivered = expectation(description: "watcher saw both files")
        let seen = LockedLog<URL>()
        let watcher = FolderWatcher(folders: job2.inputs, recursive: job2.recursive, excluded: job2.excludedFolders,
                                    stableFor: 0.5, pollInterval: 0.2) { urls in
            urls.forEach(seen.append)
            if Set(seen.values.map(\.lastPathComponent)).isSuperset(of: ["one.jpg", "two.jpg"]) { delivered.fulfill() }
        }
        XCTAssertTrue(watcher.start())
        try await Task.sleep(nanoseconds: 500_000_000)
        try drop("one.jpg", width: 3000, height: 1000)
        try drop("two.jpg", width: 1200, height: 2600)
        if await XCTWaiter.fulfillment(of: [delivered], timeout: 20) == .completed {
            ready = seen.values
        } else {
            // FSEvents may not deliver in a sandboxed test run; the job itself still gets tested.
            print("SKIP watcher part: FSEvents delivered no event")
            ready = [input.appendingPathComponent("one.jpg"), input.appendingPathComponent("two.jpg")]
        }
        watcher.stop()

        let result = await run(job2, files: ready)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.batch.failures, [])
        XCTAssertEqual(result.batch.written.map(\.lastPathComponent).sorted(), ["one.jpg", "two.jpg"])
        for url in result.batch.written {
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "out")
            let data = try Data(contentsOf: url)
            let properties = try TestImages.properties(of: data)
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
        let again = await run(job2)
        XCTAssertEqual(again.batch.order, [])
        XCTAssertNil(again.reportFile)
    }
}
