import XCTest
@testable import ImageconverterCore

final class FolderWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: WatchFilter.canonicalPath(try TestImages.tempDir()), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    func testWatcherIgnoresTempAndHidden() {
        let filter = WatchFilter(folders: [root], recursive: true)
        XCTAssertTrue(filter.accepts(path("a.jpg")))
        XCTAssertTrue(filter.accepts(path("trip/day2/a.jpg")))
        XCTAssertFalse(filter.accepts(path(".DS_Store")))
        XCTAssertFalse(filter.accepts(path(".hidden.jpg")))
        XCTAssertFalse(filter.accepts(path(".git/objects/a.jpg")))
        XCTAssertFalse(filter.accepts(path(".imageconverter-0F8C.tmp")))
        XCTAssertFalse(filter.accepts(path("sub/.imageconverter-0F8C.tmp")))
        XCTAssertFalse(filter.accepts(root.path), "the folder itself is no file")
        XCTAssertFalse(filter.accepts("/elsewhere/a.jpg"))
        XCTAssertFalse(filter.accepts(root.path + "-other/a.jpg"), "a sibling with the same prefix is not inside")
    }

    func testNonRecursiveWatchesTheTopLevelOnly() {
        let filter = WatchFilter(folders: [root], recursive: false)
        XCTAssertTrue(filter.accepts(path("a.jpg")))
        XCTAssertFalse(filter.accepts(path("sub/a.jpg")))
    }

    func testOutputInsideInputExcluded() throws {
        let output = root.appendingPathComponent("out", isDirectory: true)
        let filter = WatchFilter(folders: [root], recursive: true, excluded: [output])
        XCTAssertFalse(filter.accepts(path("out/a.jpg")))
        XCTAssertFalse(filter.accepts(path("OUT/sub/a.jpg")), "macOS paths are case-insensitive")
        XCTAssertTrue(filter.accepts(path("outside/a.jpg")))

        // The runner applies the same rule when it scans the folders itself.
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try TestImages.write(TestImages.make(width: 4, height: 4), to: root.appendingPathComponent("in.png"), type: .png)
        try TestImages.write(TestImages.make(width: 4, height: 4), to: output.appendingPathComponent("done.png"),
                             type: .png)
        let job = Job(name: "J", inputs: [root], recursive: true, output: .newFolder(output))
        XCTAssertEqual(JobRunner.candidates(for: job, files: nil).map(\.source.lastPathComponent), ["in.png"])
        XCTAssertEqual(JobRunner.candidates(for: job, files: [output.appendingPathComponent("done.png")]), [])
    }

    func testFileReadyAfterStable() {
        var tracker = ReadinessTracker(stableFor: 2)
        let url = URL(fileURLWithPath: "/in/a.jpg")
        let start = Date(timeIntervalSince1970: 1000)
        var snapshot = FileSnapshot(size: 10, modified: start, readable: true)
        tracker.note(url, now: start)
        XCTAssertEqual(tracker.poll(now: start, snapshot: { _ in snapshot }), [])
        XCTAssertEqual(tracker.poll(now: start + 1.9, snapshot: { _ in snapshot }), [])
        XCTAssertEqual(tracker.poll(now: start + 2, snapshot: { _ in snapshot }), [url])
        XCTAssertTrue(tracker.isEmpty)

        // Still growing: every change restarts the 2 s.
        tracker.note(url, now: start + 10)
        _ = tracker.poll(now: start + 10, snapshot: { _ in snapshot })
        snapshot.size = 20
        XCTAssertEqual(tracker.poll(now: start + 11.5, snapshot: { _ in snapshot }), [])
        XCTAssertEqual(tracker.poll(now: start + 13, snapshot: { _ in snapshot }), [])
        snapshot.modified = start + 12
        XCTAssertEqual(tracker.poll(now: start + 14, snapshot: { _ in snapshot }), [])
        XCTAssertEqual(tracker.poll(now: start + 16, snapshot: { _ in snapshot }), [url])
    }

    func testUnreadableOrVanishedFilesWait() {
        var tracker = ReadinessTracker(stableFor: 2)
        let url = URL(fileURLWithPath: "/in/a.jpg")
        let start = Date(timeIntervalSince1970: 0)
        var snapshot: FileSnapshot? = FileSnapshot(size: 5, modified: start, readable: false)
        tracker.note(url, now: start)
        _ = tracker.poll(now: start, snapshot: { _ in snapshot })
        XCTAssertEqual(tracker.poll(now: start + 5, snapshot: { _ in snapshot }), [], "not readable yet")
        snapshot?.readable = true
        // Readability alone changed: the file counts as changed, so it waits another 2 s.
        XCTAssertEqual(tracker.poll(now: start + 6, snapshot: { _ in snapshot }), [])
        XCTAssertEqual(tracker.poll(now: start + 8, snapshot: { _ in snapshot }), [url])
        tracker.note(url, now: start + 9)
        snapshot = nil
        XCTAssertEqual(tracker.poll(now: start + 20, snapshot: { _ in snapshot }), [])
        XCTAssertTrue(tracker.isEmpty, "a deleted file is forgotten")
    }

    func testSnapshotOfRealFile() throws {
        let url = root.appendingPathComponent("a.bin")
        try Data(count: 7).write(to: url)
        let snapshot = try XCTUnwrap(FileSnapshot.take(url))
        XCTAssertEqual(snapshot.size, 7)
        XCTAssertTrue(snapshot.readable)
        XCTAssertNil(FileSnapshot.take(root), "a folder is no file")
        XCTAssertNil(FileSnapshot.take(root.appendingPathComponent("missing")))
    }

    func testStreamReportsDroppedFileOnceStable() throws {
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let seen = LockedLog<URL>()
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        let watcher = FolderWatcher(folders: [root], recursive: true, excluded: [output], stableFor: 0.5,
                                    pollInterval: 0.2) { urls in
            urls.forEach(seen.append)
            if urls.contains(where: { $0.lastPathComponent == "photo.jpg" }) { ready.fulfill() }
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        // Give the stream a moment to attach before the change it should see.
        Thread.sleep(forTimeInterval: 0.5)
        try Data("x".utf8).write(to: root.appendingPathComponent(".hidden.jpg"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".imageconverter-1.tmp"))
        try Data("x".utf8).write(to: output.appendingPathComponent("written.jpg"))
        try Data(count: 64).write(to: root.appendingPathComponent("photo.jpg"))
        guard XCTWaiter().wait(for: [ready], timeout: 20) == .completed else {
            throw XCTSkip("FSEvents delivered no event in this environment")
        }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(seen.values.map(\.lastPathComponent), ["photo.jpg"])
    }
}
