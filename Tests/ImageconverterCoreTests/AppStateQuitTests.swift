import ImageIO
@testable import ImageconverterCore
import XCTest

/// Task 9: fresh data after an overwrite run (C1), Shortcuts actions one at a time (B2), clean quits (C3, C4, D1)
/// and a refused resume kept (C5).
final class AppStateQuitTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private static let gps: [String: Any] = [
        kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSLatitude as String: 59.33, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 18.07, kCGImagePropertyGPSLongitudeRef as String: "E",
        ],
    ]

    // MARK: C1

    func testOverwriteRunRefreshesPrivacyEstimateAndMetadata() async throws {
        let url = try MetadataTestSupport.source(dir.appendingPathComponent("photo.jpg"), properties: Self.gps)
        let before = FileVersion(url)
        let sourceKey = FocusCache.sourceKey(for: url)
        let cache = PrivacyCache()
        let found = await cache.findings(for: url)
        XCTAssertTrue(found.findings.contains { $0.kind == .location })
        XCTAssertTrue(MetadataInspection.read(url).entries.contains { $0.group == .location })
        XCTAssertEqual(FileVersion.changed([url: before]), [], "an unchanged file keeps its version")

        let pipeline = Pipeline(output: OutputSettings(format: .jpeg),
                                metadata: MetadataOptions(isEnabled: true, removeLocation: true))
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: pipeline, mode: .overwrite,
                                           trash: { _ in })
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written, [url], "replaced in place: same URL")

        // Everything keyed by the file's version sees the rewritten file.
        XCTAssertNotEqual(FileVersion(url), before)
        XCTAssertEqual(FileVersion.changed([url: before]), [url])
        XCTAssertNotEqual(FocusCache.sourceKey(for: url), sourceKey, "decodes and detections are keyed by version")
        let after = await cache.findings(for: url)
        XCTAssertFalse(after.findings.contains { $0.kind == .location }, "\(after.findings)")
        let scans = await cache.scanCount
        XCTAssertEqual(scans, 2, "the rewritten file was scanned again")
        XCTAssertFalse(MetadataInspection.read(url).entries.contains { $0.group == .location })
        // A file that went away counts as changed too.
        let rewritten = FileVersion(url)
        try FileManager.default.removeItem(at: url)
        XCTAssertNotEqual(FileVersion(url), rewritten)
        XCTAssertEqual(FileVersion.changed([url: rewritten]), [url])
    }

    // MARK: B2

    func testShortcutsActionsRunOneAtATime() async throws {
        let queue = AutomationQueue()
        let log = LockedLog<String>()
        func action(_ number: Int) -> Task<[String], Error> {
            Task {
                try await queue.run {
                    log.append("start \(number)")
                    try await Task.sleep(for: .milliseconds(60))
                    log.append("end \(number)")
                    return ["out-\(number).jpg"]
                }
            }
        }
        let first = action(1)
        try await waitUntil { await queue.isRunning }
        let second = action(2)
        try await waitUntil { await queue.waitingCount == 1 }
        let third = action(3)
        try await waitUntil { await queue.waitingCount == 2 }

        let results = try await [first.value, second.value, third.value]
        XCTAssertEqual(results, [["out-1.jpg"], ["out-2.jpg"], ["out-3.jpg"]], "each action returns its own files")
        XCTAssertEqual(log.values, ["start 1", "end 1", "start 2", "end 2", "start 3", "end 3"],
                       "never overlapping, first come first served")
        let running = await queue.isRunning
        XCTAssertFalse(running)

        // An action cancelled while it waits leaves the queue; the next one still runs.
        let holder = action(4)
        try await waitUntil { await queue.isRunning }
        let cancelled = action(5)
        try await waitUntil { await queue.waitingCount == 1 }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("a cancelled waiting action doesn't run")
        } catch is CancellationError {}
        _ = try await holder.value
        let after = try await action(6).value
        XCTAssertEqual(after, ["out-6.jpg"])
        XCTAssertFalse(log.values.contains("start 5"))
    }

    // MARK: C4

    func testActionRefusedWhileQuitting() async throws {
        let queue = AutomationQueue()
        let release = AsyncFlag()
        let running = Task { try await queue.run { await release.wait(); return 1 } }
        try await waitUntil { await queue.isRunning }
        let waiting = Task { try await queue.run { 2 } }
        try await waitUntil { await queue.waitingCount == 1 }

        await queue.stop()
        do {
            _ = try await waiting.value
            XCTFail("a waiting action is refused when quitting")
        } catch let error as AutomationError {
            XCTAssertEqual(error, .quitting)
        }
        do {
            _ = try await queue.run { 3 }
            XCTFail("a new action is refused when quitting")
        } catch let error as AutomationError {
            XCTAssertEqual(error, .quitting)
            XCTAssertEqual(Automation.message(for: error), "imageconverter is quitting.")
        }
        await release.set()
        let first = try await running.value
        XCTAssertEqual(first, 1, "the running one is cancelled by its owner, not refused here")
    }

    // MARK: C3

    func testRunJobWaitersAnsweredOnQuit() {
        var list = RunWaiterList<Int>()
        let jobA = UUID(), jobB = UUID()
        var answers: [String: RunWaitOutcome<Int>] = [:]
        list.add(jobA, skips: 0) { answers["A"] = $0 }  // queued behind another job
        list.add(jobB, skips: 1) { answers["B"] = $0 }  // B was running: waits for the follow-up
        // The quit cancels B's current run: it ends and uses up the skip; the dropped follow-up never comes.
        list.resume(jobB, with: 5)
        XCTAssertNil(answers["B"])
        XCTAssertEqual(list.count, 2)

        list.answerAllForQuit()
        XCTAssertEqual(list.count, 0)
        guard case .quitting = answers["A"], case .quitting = answers["B"] else {
            return XCTFail("every waiter is answered with quitting: \(answers)")
        }
        // Asked while quitting: answered at once.
        var late: RunWaitOutcome<Int>?
        list.add(jobA, skips: 0) { late = $0 }
        guard case .quitting = late else { return XCTFail("late waiter: \(String(describing: late))") }
        XCTAssertEqual(AutomationError.quitting.message, "imageconverter is quitting.")

        // Not quitting: a run that never started says so, a finished one hands its result.
        var normal = RunWaiterList<Int>()
        var outcomes: [RunWaitOutcome<Int>] = []
        normal.add(jobA, skips: 0) { outcomes.append($0) }
        normal.add(jobB, skips: 0) { outcomes.append($0) }
        normal.resume(jobA, with: nil)
        normal.resume(jobB, with: 7)
        guard outcomes.count == 2, case .didNotRun = outcomes[0], case .finished(7) = outcomes[1] else {
            return XCTFail("\(outcomes)")
        }
    }

    // MARK: C5

    func testResumeKeptWhenStartRefused() {
        for start in [RunStart.noAccess, .busy] {
            let outcome = ResumeStart.after(start)
            XCTAssertTrue(outcome.keepsInterruptedRun, "\(start)")
            XCTAssertTrue(outcome.asksAgain, "\(start)")
            XCTAssertEqual(outcome.toastTitle, "The interrupted batch didn't start")
            XCTAssertTrue(outcome.toastDescription?.contains("It's kept") ?? false)
        }
        XCTAssertTrue(ResumeStart.after(.noAccess).toastDescription?.contains("folder") ?? false)
        XCTAssertTrue(ResumeStart.after(.busy).toastDescription?.contains("Another conversion started first") ?? false)
        let started = ResumeStart.after(.started)
        XCTAssertFalse(started.keepsInterruptedRun)
        XCTAssertNil(started.toastTitle)
        XCTAssertFalse(started.asksAgain)
    }

    /// A resumed batch that started is no longer "interrupted": the in-memory reference goes (the running batch owns
    /// the journal file now), so the next Run, Service, link or script isn't asked about it.
    func testResumeStartedClearsInterruptedRun() {
        XCTAssertTrue(ResumeStart.after(.started).clearsInterruptedRun)
        XCTAssertFalse(ResumeStart.after(.busy).clearsInterruptedRun)
        XCTAssertFalse(ResumeStart.after(.noAccess).clearsInterruptedRun)
    }

    // MARK: D1

    @MainActor
    func testQuitWaitsForInstall() async throws {
        let activity = InstallActivity()
        XCTAssertFalse(activity.isInstalling)
        try await activity.perform {
            XCTAssertTrue(activity.isInstalling, "installing from the service call's start…")
            let work = RunningWork(installingUpdate: activity.isInstalling)
            XCTAssertTrue(work.anything)
            let question = try XCTUnwrap(QuitPolicy.question(for: work))
            XCTAssertNil(question.stopButton, "no Quit anyway while the service swaps the app")
            XCTAssertEqual(question.cancelButton, "Wait")
        }
        XCTAssertFalse(activity.isInstalling, "…until it returns")
        struct Refused: Error {}
        do {
            try await activity.perform { throw Refused() }
        } catch {}
        XCTAssertFalse(activity.isInstalling, "also when the install throws")

        // Installing wins over everything else that runs (no Stop and Quit).
        let both = QuitPolicy.question(for: RunningWork(manualBatch: true, jobs: 1, installingUpdate: true))
        XCTAssertNil(both?.stopButton)
        let batch = try XCTUnwrap(QuitPolicy.question(for: RunningWork(manualBatch: true, actions: 2)))
        XCTAssertEqual(batch.stopButton, "Stop and Quit")
        XCTAssertEqual(batch.message, "imageconverter is converting a batch and 2 Shortcuts actions. Files already "
            + "written are kept; the rest is not converted. Nothing half-written is left behind.")
        XCTAssertNil(QuitPolicy.question(for: RunningWork()))
    }

    // MARK: Helpers

    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition never became true")
    }
}

/// A one-shot signal for async tests.
private actor AsyncFlag {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        isSet = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
