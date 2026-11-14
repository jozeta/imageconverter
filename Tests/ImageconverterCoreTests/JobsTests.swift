import XCTest
@testable import ImageconverterCore

final class JobsTests: XCTestCase {
    private var root: URL!
    private var store: JobStore!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
        store = JobStore(directory: root.appendingPathComponent("jobs", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleJob(name: String = "Web drop") -> Job {
        Job(name: name, pipeline: Pipeline(output: OutputSettings(format: .png)),
            presetID: UUID(), inputs: [URL(fileURLWithPath: "/Users/me/Drop", isDirectory: true)], recursive: true,
            output: .newFolder(URL(fileURLWithPath: "/Users/me/Drop/out", isDirectory: true)),
            trigger: .schedule(every: 900), report: .csv, isEnabled: false)
    }

    func testJobRoundTrip() throws {
        let job = sampleJob()
        try store.save(job)
        try store.saveLedger(ProcessedLedger(), id: job.id)
        let loaded = store.load()
        XCTAssertEqual(loaded.jobs, [job])
        // The ledger next to it is neither a job nor a skipped file.
        XCTAssertTrue(loaded.skipped.isEmpty, "\(loaded.skipped)")
        let file = try String(contentsOf: store.directory.appendingPathComponent("\(job.id.uuidString).json"))
        XCTAssertTrue(file.contains("\"schemaVersion\" : 1"))
    }

    func testScheduleIsClampedAndNextRunAddsTheInterval() throws {
        var job = sampleJob()
        job.trigger = .schedule(every: 10)
        try store.save(job)
        XCTAssertEqual(store.load().jobs.first?.trigger, .schedule(every: 300))
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(JobSchedule.nextRun(after: start, interval: 60), start.addingTimeInterval(300))
        XCTAssertEqual(JobSchedule.nextRun(after: start, interval: 3600), start.addingTimeInterval(3600))
        XCTAssertEqual(JobSchedule.clamped(.infinity), 300)
        XCTAssertEqual(JobSchedule.clamped(1e12), JobSchedule.maximumInterval)
    }

    func testJobFilesWithForeignURLsAreSkipped() throws {
        let job = sampleJob()
        try store.save(job)
        let url = store.directory.appendingPathComponent("\(job.id.uuidString).json")
        // JSONEncoder escapes slashes in URLs.
        let original = try String(contentsOf: url)
        XCTAssertTrue(original.contains(#"file:\/\/\/"#))
        let text = original.replacingOccurrences(of: #"file:\/\/\/"#, with: #"https:\/\/evil.example\/"#)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let loaded = store.load()
        XCTAssertEqual(loaded.jobs, [])
        XCTAssertEqual(loaded.skipped.count, 1)
    }

    func testDeleteRemovesTheLedger() throws {
        let job = sampleJob()
        try store.save(job)
        var ledger = ProcessedLedger()
        ledger.record([FileFingerprint(path: "/a.jpg", size: 1, modified: 2)])
        try store.saveLedger(ledger, id: job.id)
        XCTAssertEqual(try store.loadLedger(id: job.id), ledger)
        try store.delete(id: job.id)
        XCTAssertEqual(store.load().jobs, [])
        XCTAssertEqual(try store.loadLedger(id: job.id).count, 0)
    }

    func testLedgerMatchesPathSizeAndDate() {
        var ledger = ProcessedLedger()
        let print = FileFingerprint(path: "/in/a.jpg", size: 100, modified: 1_700_000_000.123456)
        ledger.record([print])
        XCTAssertTrue(ledger.contains(print))
        XCTAssertFalse(ledger.contains(FileFingerprint(path: "/in/a.jpg", size: 101, modified: print.modified)))
        XCTAssertFalse(ledger.contains(FileFingerprint(path: "/in/a.jpg", size: 100, modified: print.modified + 1)))
        XCTAssertFalse(ledger.contains(FileFingerprint(path: "/in/b.jpg", size: 100, modified: print.modified)))
    }

    func testLedgerCapDropsTheOldest() throws {
        var ledger = ProcessedLedger()
        let all = (0..<(ProcessedLedger.maxEntries + 5)).map {
            FileFingerprint(path: "/in/\($0).jpg", size: $0, modified: 1)
        }
        ledger.record(all)
        XCTAssertEqual(ledger.count, ProcessedLedger.maxEntries)
        XCTAssertFalse(ledger.contains(all[4]))
        XCTAssertTrue(ledger.contains(all[5]))
        XCTAssertTrue(ledger.contains(all[all.count - 1]))
        let decoded = try JSONDecoder().decode(ProcessedLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
    }

    func testGarbageLedgerIsAnErrorNotAnEmptyList() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{\"entries\":[{\"path\":\"relative\",\"size\":1,\"modified\":1}]}".utf8)
            .write(to: store.ledgerURL(for: id))
        XCTAssertThrowsError(try store.loadLedger(id: id))
        try Data("not json".utf8).write(to: store.ledgerURL(for: id))
        XCTAssertThrowsError(try store.loadLedger(id: id))
        try store.resetLedger(id: id)
        XCTAssertEqual(try store.loadLedger(id: id).count, 0)
    }

    func testLinkedLedgerIsRejected() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.ledgerURL(for: id),
                                                   withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try store.loadLedger(id: id))
    }

    func testSchedulerFiresRepeatedlyUntilCancelled() {
        let scheduler = JobScheduler(queue: DispatchQueue(label: "test"), minimumInterval: 0.1)
        let id = UUID()
        let fired = expectation(description: "fired twice")
        fired.expectedFulfillmentCount = 2
        fired.assertForOverFulfill = false
        scheduler.schedule(id, every: 0.1) { fired.fulfill() }
        wait(for: [fired], timeout: 5)
        XCTAssertEqual(scheduler.scheduledIDs, [id])
        scheduler.cancel(id)
        XCTAssertTrue(scheduler.scheduledIDs.isEmpty)
    }

    func testPublicSchedulerKeepsTheMinimum() {
        let scheduler = JobScheduler()
        let fired = expectation(description: "not fired")
        fired.isInverted = true
        scheduler.schedule(UUID(), every: 0.05) { fired.fulfill() }
        wait(for: [fired], timeout: 0.5)
        scheduler.cancelAll()
    }
}
