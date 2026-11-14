import XCTest
@testable import ImageconverterCore

final class RunJournalTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var journalURL: URL { root.appendingPathComponent("support/imageconverter/journal.json") }

    private func files(_ count: Int) throws -> [URL] {
        let src = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        return try (1...count).map { index in
            let url = src.appendingPathComponent("img\(index).png")
            try TestImages.write(TestImages.make(width: 20, height: 20), to: url, type: .png)
            return url
        }
    }

    func testJournalWrittenAndClearedAndRecovered() async throws {
        let urls = try files(3)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let pipeline = Pipeline(output: .init(format: .jpeg))
        let seen = LockedLog<RunJournal>()
        let journalURL = journalURL
        let report = await BatchRunner.run(
            InputCollector.collect(urls), pipeline: pipeline, mode: .newFolder(out), concurrency: 1,
            journal: journalURL, events: { event in
                // Read while the run is going: the journal is already on disk.
                if event.stage == .decoding, event.index == 0, let journal = RunJournal.pending(at: journalURL) {
                    seen.append(journal)
                }
            })
        XCTAssertEqual(report.written.count, 3)
        let during = try XCTUnwrap(seen.values.first)
        XCTAssertEqual(during.inputItems.map(\.source), urls)
        XCTAssertEqual(during.pipeline, pipeline)
        XCTAssertEqual(during.outputMode, .newFolder(out))
        XCTAssertEqual(during.completed, [])
        // A normal finish deletes it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertNil(RunJournal.pending(at: journalURL))

        // An interrupted run leaves one behind; the next launch finds it with what is left to do.
        var crashed = RunJournal(items: InputCollector.collect(urls), pipeline: pipeline, mode: .overwrite)
        crashed.completed = [0, 2]
        try crashed.write(to: journalURL)
        let recovered = try XCTUnwrap(RunJournal.pending(at: journalURL))
        XCTAssertEqual(recovered, crashed)
        XCTAssertEqual(recovered.remainingItems.map(\.source), [urls[1]])
        RunJournal.discard(at: journalURL)
        XCTAssertNil(RunJournal.pending(at: journalURL))
    }

    func testCancelledRunDeletesTheJournal() async throws {
        let urls = try files(2)
        let control = BatchControl()
        control.pause()
        let journalURL = journalURL
        let task = Task {
            await BatchRunner.run(InputCollector.collect(urls), pipeline: Pipeline(),
                                  mode: .newFolder(root.appendingPathComponent("out")), control: control,
                                  journal: journalURL)
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: journalURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(RunJournal.pending(at: journalURL))
        task.cancel()
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testJournalMarksCompletedItemsInBatchesAndOnATimer() throws {
        let items = (0..<50).map { InputItem(source: URL(fileURLWithPath: "/tmp/\($0).png"), relativeDirectory: "") }
        let writer = RunJournalWriter(url: journalURL,
                                      journal: RunJournal(items: items, pipeline: Pipeline(), mode: .overwrite),
                                      interval: 0.3)
        writer.writeNow()
        for index in 0..<19 { writer.markCompleted(index) }
        writer.waitForWrites()
        XCTAssertEqual(try mainFile().completed, [], "Fewer than 20: the timer hasn't fired")
        XCTAssertEqual(RunJournal.pending(at: journalURL)?.completed, Array(0..<19), "The completion log has them at once")
        writer.markCompleted(19)
        writer.waitForWrites()
        XCTAssertEqual(try mainFile().completed, Array(0..<20), "20 write at once")
        writer.markCompleted(25)
        writer.markCompleted(25)
        Thread.sleep(forTimeInterval: 0.6)
        writer.waitForWrites()
        XCTAssertEqual(try mainFile().completed, Array(0..<20) + [25], "The timer wrote it")
        writer.remove()
        writer.markCompleted(30)
        Thread.sleep(forTimeInterval: 0.4)
        writer.waitForWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path), "Nothing is written after remove")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RunJournal.completionLogURL(for: journalURL).path))
    }

    /// The journal file alone, without the completion log.
    private func mainFile() throws -> RunJournal {
        try JSONDecoder().decode(RunJournal.self, from: Data(contentsOf: journalURL))
    }

    func testHostileCompletionLogLinesAreIgnored() throws {
        let items = (0..<3).map { InputItem(source: URL(fileURLWithPath: "/tmp/\($0).png"), relativeDirectory: "") }
        try RunJournal(items: items, pipeline: Pipeline(), mode: .sameFolder(suffix: "_n")).write(to: journalURL)
        try Data("1\n-4\n99\nxyz\n2\n".utf8).write(to: RunJournal.completionLogURL(for: journalURL))
        XCTAssertEqual(RunJournal.pending(at: journalURL)?.completed, [1, 2])
        RunJournal.discard(at: journalURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RunJournal.completionLogURL(for: journalURL).path))
    }

    /// Final review I1: an overwrite batch "crashes" right after replacing an original, before the journal or
    /// even the completion log has it. Resuming must not process that original a second time.
    func testResumeAfterCrashDoesNotReprocessReplacedOriginals() async throws {
        let urls = try files(3)
        let journalURL = journalURL
        let logURL = RunJournal.completionLogURL(for: journalURL)
        let crash = root.appendingPathComponent("crash", isDirectory: true)
        try FileManager.default.createDirectory(at: crash, withIntermediateDirectories: true)
        let crashJournal = crash.appendingPathComponent("journal.json")
        let crashLog = RunJournal.completionLogURL(for: crashJournal)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw90)))],
                                output: OutputSettings(format: .png))
        let report = await BatchRunner.run(
            InputCollector.collect(urls), pipeline: pipeline, mode: .overwrite, concurrency: 1,
            trash: { _ in XCTFail("in place, nothing is trashed") }, journal: journalURL, events: { event in
                // `.done` of item 1 is sent before item 1 is recorded: the disk now looks like a crash then.
                guard event.index == 1, event.stage == .done else { return }
                try? FileManager.default.copyItem(at: journalURL, to: crashJournal)
                try? FileManager.default.copyItem(at: logURL, to: crashLog)
            })
        XCTAssertEqual(report.failures, [])
        let crashed = try XCTUnwrap(RunJournal.pending(at: crashJournal))
        XCTAssertEqual(crashed.completed, [0], "item 0 came from the completion log")
        XCTAssertNotNil(crashed.items[1].size, "overwrite mode records each source's fingerprint")
        let plan = ResumePlan.make(journal: crashed, existing: [],
                                   fileExists: { FileManager.default.fileExists(atPath: $0) },
                                   directoryExists: { _ in true })
        XCTAssertFalse(plan.toRun.map(\.source).contains(urls[1]), "item 1 was replaced and must not run again")
        XCTAssertTrue(plan.alreadyReplaced.contains(urls[1]))
        XCTAssertTrue(plan.toRun.isEmpty, "every original was replaced by the end of the run")
    }

    func testCompletedIsStoredAsRuns() throws {
        let items = (0..<100_000).map { InputItem(source: URL(fileURLWithPath: "/p/\($0).jpg"), relativeDirectory: "") }
        var journal = RunJournal(items: items, pipeline: Pipeline(), mode: .overwrite)
        journal.completed = Array(0..<99_998) + [99_999]
        try journal.write(to: journalURL)
        let text = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"completed\":[[0,99997],[99999,99999]]"))
        XCTAssertEqual(RunJournal.pending(at: journalURL)?.completed.count, 99_999)
        XCTAssertEqual(RunJournal.runs([3, 1, 2, 2, 7]), [[1, 3], [7, 7]])
        XCTAssertEqual(RunJournal.expand([[1, 3], [7, 7]], count: 8), [1, 2, 3, 7])
        // Overlapping, touching, reversed, out of range or malformed runs are refused.
        for runs in [[[1, 3], [2, 5]], [[1, 3], [4, 5]], [[3, 1]], [[0, 8]], [[1]], [[-1, 0]]] {
            XCTAssertNil(RunJournal.expand(runs, count: 8), "\(runs)")
        }
    }

    func testHostileJournalsAreRejected() throws {
        let items = [InputItem(source: URL(fileURLWithPath: "/tmp/a.png"), relativeDirectory: "")]
        let good = RunJournal(items: items, pipeline: Pipeline(), mode: .sameFolder(suffix: "_new"))
        try good.write(to: journalURL)
        XCTAssertNotNil(RunJournal.pending(at: journalURL))

        // Garbage, a future version, out-of-range indices and relative paths are refused.
        try Data("{not json".utf8).write(to: journalURL)
        XCTAssertNil(RunJournal.pending(at: journalURL))
        for mutate in [
            { (journal: inout RunJournal) in journal.schemaVersion = 99 },
            { (journal: inout RunJournal) in journal.completed = [5] },
            { (journal: inout RunJournal) in journal.items = [.init(path: "relative.png", relativeDirectory: "")] },
            { (journal: inout RunJournal) in journal.items = [.init(path: "/tmp/a\u{0}.png", relativeDirectory: "")] },
            { (journal: inout RunJournal) in journal.outputMode = .newFolder(URL(string: "https://example.com")!) },
        ] {
            var journal = good
            mutate(&journal)
            try journal.write(to: journalURL)
            XCTAssertNil(RunJournal.pending(at: journalURL))
        }

        // A symbolic link is never followed.
        let real = root.appendingPathComponent("real.json")
        try good.write(to: real)
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: real)
        XCTAssertNil(RunJournal.pending(at: journalURL))

        // Oversized files are refused before decoding.
        try FileManager.default.removeItem(at: journalURL)
        try Data(repeating: 0x20, count: RunJournal.maxFileSize + 1).write(to: journalURL)
        XCTAssertNil(RunJournal.pending(at: journalURL))
    }

    func testDefaultLocationIsInApplicationSupport() throws {
        let url = try XCTUnwrap(RunJournal.defaultURL)
        XCTAssertEqual(url.lastPathComponent, "journal.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "imageconverter")
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    // MARK: Stale temp files

    private func makeFile(_ name: String, in folder: URL, age: TimeInterval) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        let date = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    func testStaleTempFilesRemovedOnlyByPattern() async throws {
        let urls = try files(1)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let uuid = UUID().uuidString
        let hour: TimeInterval = 3600
        let stale = try makeFile(".imageconverter-\(uuid).tmp", in: out, age: 2 * hour)
        let staleInSource = try makeFile(".imageconverter-\(UUID().uuidString).tmp",
                                         in: urls[0].deletingLastPathComponent(), age: 2 * hour)
        let kept = try [
            makeFile(".imageconverter-\(UUID().uuidString).tmp", in: out, age: 60), // fresh: maybe in use
            makeFile(".imageconverter-notauuid.tmp", in: out, age: 2 * hour),
            makeFile("x.imageconverter-\(UUID().uuidString).tmp", in: out, age: 2 * hour),
            makeFile(".imageconverter-\(UUID().uuidString).tmp.jpg", in: out, age: 2 * hour),
            makeFile(".imageconverter-\(UUID().uuidString.lowercased()).TMP", in: out, age: 2 * hour),
            makeFile("photo.jpg", in: out, age: 2 * hour),
        ]
        // A folder and a link with the exact name are not regular files: never removed.
        let folder = out.appendingPathComponent(".imageconverter-\(UUID().uuidString).tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = out.appendingPathComponent(".imageconverter-\(UUID().uuidString).tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: kept[5])
        let target = try makeFile("target.txt", in: root, age: 2 * hour)
        let linkOut = out.appendingPathComponent(".imageconverter-\(UUID().uuidString).tmp")
        try FileManager.default.createSymbolicLink(at: linkOut, withDestinationURL: target)

        let report = await BatchRunner.run(InputCollector.collect(urls), pipeline: Pipeline(output: .init(format: .jpeg)),
                                           mode: .newFolder(out))
        XCTAssertEqual(report.written.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        // New-folder mode only cleans the chosen folder.
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleInSource.path))
        for url in kept { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: linkOut.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        // Same-folder mode cleans the sources' folders.
        _ = await BatchRunner.run(InputCollector.collect(urls), pipeline: Pipeline(output: .init(format: .jpeg)),
                                  mode: .sameFolder(suffix: "_new"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleInSource.path))
    }

    func testStaleTempFolders() {
        func plan(_ source: String, _ destination: String) -> PlannedOutput {
            PlannedOutput(item: InputItem(source: URL(fileURLWithPath: source), relativeDirectory: ""),
                          destination: URL(fileURLWithPath: destination), replacesSource: false, trashesSource: false)
        }
        let plans = [plan("/a/one.png", "/out/one.jpg"), plan("/a/two.png", "/out/sub/two.jpg"),
                     plan("/b/three.png", "/out/three.jpg"), plan("/b/four.png", "/b/four.jpg")]
        XCTAssertEqual(StaleTempFiles.folders(for: plans).map(\.path), ["/out", "/out/sub", "/b"])
    }
}
