import XCTest
@testable import ImageconverterCore

final class FolderAccessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBookmarkResolvesAndFollowsAMovedFolder() throws {
        let incoming = try folder("Incoming")
        let data = try XCTUnwrap(FolderAccess.bookmark(for: incoming))
        XCTAssertEqual(FolderAccess.resolve(data)?.url.standardizedFileURL.path, incoming.path)

        let moved = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: incoming, to: moved)
        let resolved = try XCTUnwrap(FolderAccess.resolve(data))
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().path, moved.path)
    }

    func testDeletedFolderDoesNotResolve() throws {
        let incoming = try folder("Incoming")
        let data = try XCTUnwrap(FolderAccess.bookmark(for: incoming))
        try FileManager.default.removeItem(at: incoming)
        XCTAssertNil(FolderAccess.resolve(data))
        XCTAssertNil(FolderAccess.resolve(Data("not a bookmark".utf8)))
    }

    func testWithAccessRunsTheBodyForPlainURLs() throws {
        let incoming = try folder("Incoming")
        XCTAssertEqual(FolderAccess.withAccess([incoming]) { 42 }, 42)
    }

    // MARK: JobFolders

    private func job(inputs: [URL], output: OutputMode, bookmarks: [Data]? = nil, outputBookmark: Data? = nil) -> Job {
        Job(name: "Auto", inputs: inputs, output: output, inputBookmarks: bookmarks, outputBookmark: outputBookmark)
    }

    func testMissingBookmarksAreCreatedForExistingFolders() throws {
        let incoming = try folder("Incoming")
        let out = try folder("Out")
        let outcome = JobFolders.resolve(job(inputs: [incoming], output: .newFolder(out)), sandboxed: false,
                                         resolver: { _ in nil }, bookmarker: { Data($0.lastPathComponent.utf8) })
        guard case .ready(let ready, let changed) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(changed)
        XCTAssertEqual(ready.inputBookmarks, [Data("Incoming".utf8)])
        XCTAssertEqual(ready.outputBookmark, Data("Out".utf8))
        XCTAssertEqual(ready.inputs, [incoming])
    }

    func testMovedFolderAndStaleBookmarkUpdateTheJob() throws {
        let moved = try folder("Moved")
        let gone = root.appendingPathComponent("Incoming", isDirectory: true)
        let old = Data("old".utf8)
        let outcome = JobFolders.resolve(
            job(inputs: [gone], output: .sameFolder(suffix: "_new"), bookmarks: [old], outputBookmark: Data("x".utf8)),
            sandboxed: true, resolver: { _ in FolderAccess.Resolved(url: moved, refreshed: Data("new".utf8)) },
            bookmarker: { _ in nil })
        guard case .ready(let ready, let changed) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(changed)
        // Stored as the real path, the form watchers and the ledger use.
        XCTAssertEqual(ready.inputs.map(\.path), [WatchFilter.canonicalPath(moved)])
        XCTAssertEqual(ready.inputBookmarks, [Data("new".utf8)])
        // Not a new-folder job: no output bookmark.
        XCTAssertNil(ready.outputBookmark)
    }

    func testUnchangedJobIsNotMarkedChanged() throws {
        let incoming = try folder("Incoming")
        let data = Data("ok".utf8)
        let original = job(inputs: [incoming], output: .overwrite, bookmarks: [data])
        let outcome = JobFolders.resolve(original, sandboxed: true,
                                         resolver: { _ in FolderAccess.Resolved(url: incoming) },
                                         bookmarker: { _ in XCTFail("no new bookmark needed"); return nil })
        XCTAssertEqual(outcome, .ready(original, changed: false))
    }

    func testUnresolvableInputMakesTheJobUnavailable() {
        let gone = root.appendingPathComponent("Incoming Images", isDirectory: true)
        let outcome = JobFolders.resolve(job(inputs: [gone], output: .overwrite, bookmarks: [Data("b".utf8)]),
                                         sandboxed: false, resolver: { _ in nil }, bookmarker: { _ in nil })
        XCTAssertEqual(outcome, .unavailable(reason: "The input folder \u{201C}Incoming Images\u{201D} can't be found."))
    }

    func testMissingOutputFolderIsCreatedLaterUnsandboxedButUnavailableSandboxed() throws {
        let incoming = try folder("Incoming")
        let out = root.appendingPathComponent("Processed", isDirectory: true)
        let unsandboxed = JobFolders.resolve(job(inputs: [incoming], output: .newFolder(out)), sandboxed: false,
                                             resolver: { _ in nil }, bookmarker: { _ in nil })
        guard case .ready(let ready, _) = unsandboxed else { return XCTFail("\(unsandboxed)") }
        XCTAssertEqual(ready.output, .newFolder(out))
        let sandboxed = JobFolders.resolve(job(inputs: [incoming], output: .newFolder(out)), sandboxed: true,
                                           resolver: { _ in nil }, bookmarker: { _ in nil })
        XCTAssertEqual(sandboxed, .unavailable(reason: "The output folder \u{201C}Processed\u{201D} can't be found."))
    }

    // MARK: Storage

    func testBookmarksRoundTripAndBadOnesAreDroppedNotFatal() throws {
        let store = JobStore(directory: root.appendingPathComponent("jobs", isDirectory: true))
        let input = URL(fileURLWithPath: "/Users/me/Drop", isDirectory: true)
        var job = Job(name: "Drop", inputs: [input], output: .newFolder(URL(fileURLWithPath: "/Users/me/Out")),
                      inputBookmarks: [Data("in".utf8)], outputBookmark: Data("out".utf8),
                      disabledReason: "The input folder can't be found.")
        try store.save(job)
        XCTAssertEqual(store.load().jobs, [job])

        // A bookmark list that doesn't match the inputs is ignored; the job still loads.
        job.inputBookmarks = [Data("a".utf8), Data("b".utf8)]
        try store.save(job)
        let url = store.directory.appendingPathComponent("\(job.id.uuidString).json")
        var text = try String(contentsOf: url)
        text = text.replacingOccurrences(of: Data("out".utf8).base64EncodedString(), with: "%%not base64%%")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(store.load().jobs.first)
        XCTAssertNil(loaded.inputBookmarks)
        XCTAssertNil(loaded.outputBookmark)
        XCTAssertEqual(loaded.inputs, [input])
    }

    // MARK: Moved folders

    func testLedgerFollowsAMovedFolder() throws {
        let store = JobStore(directory: root.appendingPathComponent("jobs", isDirectory: true))
        let id = UUID()
        var ledger = ProcessedLedger()
        let photo = FileFingerprint(path: "/data/Incoming/a.jpg", size: 10, modified: 1)
        let nested = FileFingerprint(path: "/data/Incoming/sub/b.jpg", size: 20, modified: 2)
        let sibling = FileFingerprint(path: "/data/Incoming Other/c.jpg", size: 30, modified: 3)
        ledger.recordProcessed([photo, nested, sibling])
        ledger.recordOutputs([FileFingerprint(path: "/data/Incoming/out/a.avif", size: 5, modified: 4)])
        try store.saveLedger(ledger, id: id)

        try store.rebaseLedger(id: id, moves: [(URL(fileURLWithPath: "/data/Incoming"),
                                                URL(fileURLWithPath: "/data/Moved"))])
        let moved = try store.loadLedger(id: id)
        XCTAssertTrue(moved.isSettled(FileFingerprint(path: "/data/Moved/a.jpg", size: 10, modified: 1)))
        XCTAssertTrue(moved.isSettled(FileFingerprint(path: "/data/Moved/sub/b.jpg", size: 20, modified: 2)))
        XCTAssertTrue(moved.isSettled(FileFingerprint(path: "/data/Moved/out/a.avif", size: 5, modified: 4)))
        XCTAssertFalse(moved.isSettled(photo))
        // Only whole path components move: a sibling with the same prefix stays.
        XCTAssertTrue(moved.isSettled(sibling))
        XCTAssertEqual(moved.count, 3)
    }

    func testLedgerRebaseMatchesTheCollectorsSpelling() throws {
        // A real moved folder under /var (a symlink to /private/var): the ledger holds InputCollector's spelling.
        let store = JobStore(directory: root.appendingPathComponent("jobs", isDirectory: true))
        let id = UUID()
        let old = try folder("Before")
        let file = old.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: file)
        let recorded = try XCTUnwrap(FileFingerprint.of(file.resolvingSymlinksInPath()))
        var ledger = ProcessedLedger()
        ledger.recordProcessed([recorded])
        try store.saveLedger(ledger, id: id)
        let new = root.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: new)
        // The job stores the real path of the old folder, which no longer exists.
        let oldReal = URL(fileURLWithPath: "/private" + old.path, isDirectory: true)
        try store.rebaseLedger(id: id, moves: [(oldReal, URL(fileURLWithPath: WatchFilter.canonicalPath(new)))])
        let moved = try XCTUnwrap(FileFingerprint.of(new.appendingPathComponent("a.jpg").resolvingSymlinksInPath()))
        XCTAssertTrue(try store.loadLedger(id: id).isSettled(moved))
    }

    func testMovesListsChangedInputsAndOutput() {
        let old = Job(name: "J", inputs: [URL(fileURLWithPath: "/a/In1"), URL(fileURLWithPath: "/a/In2")],
                      output: .newFolder(URL(fileURLWithPath: "/a/Out")))
        var new = old
        new.inputs[1] = URL(fileURLWithPath: "/b/In2")
        new.output = .newFolder(URL(fileURLWithPath: "/b/Out"))
        let moves = JobFolders.moves(from: old, to: new)
        XCTAssertEqual(moves.map(\.from.path), ["/a/In2", "/a/Out"])
        XCTAssertEqual(moves.map(\.to.path), ["/b/In2", "/b/Out"])
        XCTAssertTrue(JobFolders.moves(from: old, to: old).isEmpty)
    }
}
