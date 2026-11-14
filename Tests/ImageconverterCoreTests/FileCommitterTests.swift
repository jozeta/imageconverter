import XCTest
@testable import ImageconverterCore

final class FileCommitterTests: XCTestCase {
    private var dir: URL!
    private let files = FileManager.default

    override func setUpWithError() throws { dir = try TestImages.tempDir() }

    override func tearDown() {
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? files.removeItem(at: dir)
    }

    private func tempFiles(in directory: URL) -> [String] {
        ((try? files.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(FileCommitter.tempPrefix) }
    }

    private func plan(source: URL, destination: URL, replaces: Bool = false,
                      trashes: Bool = false) -> PlannedOutput {
        PlannedOutput(item: InputItem(source: source, relativeDirectory: ""), destination: destination,
                      replacesSource: replaces, trashesSource: trashes)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    func testRejectsPlanThatBothReplacesAndTrashesSource() throws {
        let source = dir.appendingPathComponent("in.jpg")
        try Data("orig".utf8).write(to: source)
        XCTAssertThrowsError(try FileCommitter.commit(
            Data("new".utf8), for: plan(source: source, destination: source, replaces: true, trashes: true),
            trash: { _ in XCTFail("must not trash") })) { error in
            XCTAssertEqual(error as? ConversionError, .writeFailed("Invalid output plan"))
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("orig".utf8))
    }

    func testWritesNewFileAndCreatesFolders() throws {
        let dest = dir.appendingPathComponent("a/b/out.png")
        try FileCommitter.commit(Data("new".utf8),
                                 for: plan(source: dir.appendingPathComponent("in.jpg"), destination: dest))
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertTrue(tempFiles(in: dest.deletingLastPathComponent()).isEmpty)
    }

    func testReplacesInPlace() throws {
        let file = dir.appendingPathComponent("x.png")
        try Data("old".utf8).write(to: file)
        try FileCommitter.commit(Data("new".utf8), for: plan(source: file, destination: file, replaces: true))
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        XCTAssertTrue(tempFiles(in: dir).isEmpty)
    }

    func testTrashesSourceOnFormatChange() throws {
        let source = dir.appendingPathComponent("x.jpg")
        try Data("old".utf8).write(to: source)
        let dest = dir.appendingPathComponent("x.png")
        let recorder = Recorder()
        try FileCommitter.commit(Data("new".utf8), for: plan(source: source, destination: dest, trashes: true),
                                 trash: { recorder.add($0) })
        XCTAssertEqual(recorder.all, [source])
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertTrue(tempFiles(in: dir).isEmpty)
    }

    func testTrashFailureKeepsNewFileAndThrows() throws {
        let source = dir.appendingPathComponent("x.jpg")
        try Data("old".utf8).write(to: source)
        let dest = dir.appendingPathComponent("x.png")
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        XCTAssertThrowsError(try FileCommitter.commit(
            Data("new".utf8), for: plan(source: source, destination: dest, trashes: true),
            trash: { _ in throw Boom() })) { error in
            XCTAssertEqual(error as? ConversionError,
                           .writeFailed("Converted, but couldn't move the original to the Trash: boom"))
        }
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertTrue(tempFiles(in: dir).isEmpty)
    }

    func testNoTrashWhenWriteFails() throws {
        let source = dir.appendingPathComponent("x.jpg")
        let dest = dir.appendingPathComponent("x.png")
        try Data("keep".utf8).write(to: dest)
        let recorder = Recorder()
        XCTAssertThrowsError(try FileCommitter.commit(
            Data("new".utf8), for: plan(source: source, destination: dest, trashes: true),
            trash: { recorder.add($0) }))
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testExistingDestinationIsNotClobbered() throws {
        let dest = dir.appendingPathComponent("out.png")
        try Data("keep".utf8).write(to: dest)
        XCTAssertThrowsError(try FileCommitter.commit(
            Data("new".utf8), for: plan(source: dir.appendingPathComponent("in.jpg"), destination: dest))) {
            guard case .writeFailed = $0 as? ConversionError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: dest), Data("keep".utf8))
        XCTAssertTrue(tempFiles(in: dir).isEmpty)
    }

    func testFailureLeavesNoTempFile() throws {
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try files.createDirectory(at: locked, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try FileCommitter.commit(
            Data("new".utf8),
            for: plan(source: dir.appendingPathComponent("in.jpg"),
                      destination: locked.appendingPathComponent("out.png")))) {
            guard case .writeFailed = $0 as? ConversionError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(tempFiles(in: locked).isEmpty)
    }

    // MARK: Temp clean-up

    private func makeFile(_ name: String, in folder: URL, age: TimeInterval = 0) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func testCleanupOnlyRemovesExactPattern() throws {
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try files.createDirectory(at: sub, withIntermediateDirectories: true)
        let removed = try [makeFile(".imageconverter-\(UUID().uuidString).tmp", in: dir),
                           makeFile(".imageconverter-\(UUID().uuidString).tmp", in: sub, age: 7200)]
        let kept = try [
            makeFile(".imageconverter-notauuid.tmp", in: dir),
            makeFile("x.imageconverter-\(UUID().uuidString).tmp", in: dir),
            makeFile(".imageconverter-\(UUID().uuidString).tmp.jpg", in: dir),
            makeFile(".imageconverter-\(UUID().uuidString.lowercased()).tmp", in: dir),
            makeFile(".imageconverter-\(UUID().uuidString).TMP", in: dir),
            makeFile("photo.jpg", in: dir),
        ]
        let folder = dir.appendingPathComponent(".imageconverter-\(UUID().uuidString).tmp", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = try makeFile("target.txt", in: sub)
        let link = dir.appendingPathComponent(".imageconverter-\(UUID().uuidString).tmp")
        try files.createSymbolicLink(at: link, withDestinationURL: target)
        // Not recursive: a temp file in a subfolder of a listed folder stays.
        let nested = try makeFile(".imageconverter-\(UUID().uuidString).tmp", in: folder)

        FileCommitter.cleanUp(in: [dir, sub, dir.appendingPathComponent("missing", isDirectory: true)])

        for url in removed { XCTAssertFalse(files.fileExists(atPath: url.path), url.lastPathComponent) }
        for url in kept + [folder, target, nested] {
            XCTAssertTrue(files.fileExists(atPath: url.path), url.lastPathComponent)
        }
        XCTAssertNotNil(try? files.destinationOfSymbolicLink(atPath: link.path))

        // With an age, only older files go (the run-start sweep).
        let fresh = try makeFile(".imageconverter-\(UUID().uuidString).tmp", in: dir, age: 60)
        let stale = try makeFile(".imageconverter-\(UUID().uuidString).tmp", in: dir, age: 7200)
        FileCommitter.cleanUp(in: [dir], olderThan: 3600)
        XCTAssertTrue(files.fileExists(atPath: fresh.path))
        XCTAssertFalse(files.fileExists(atPath: stale.path))
    }

    func testTempPatternMatcher() {
        XCTAssertTrue(FileCommitter.isTempFileName(".imageconverter-\(UUID().uuidString).tmp"))
        XCTAssertFalse(FileCommitter.isTempFileName(".imageconverter-\(UUID().uuidString.lowercased()).tmp"))
        XCTAssertFalse(FileCommitter.isTempFileName(".imageconverter-.tmp"))
        XCTAssertFalse(FileCommitter.isTempFileName("photo.jpg"))
    }

    func testCommitRecordsItsFolderForQuitCleanup() throws {
        let out = dir.appendingPathComponent("recorded", isDirectory: true)
        try FileCommitter.commit(Data("new".utf8), for: plan(source: dir.appendingPathComponent("in.jpg"),
                                                             destination: out.appendingPathComponent("a.png")))
        XCTAssertTrue(FileCommitter.writtenDirectories.contains(out.standardizedFileURL))
    }

    func testCancelRemovesTempFilesInDestinationFolders() async throws {
        let sources = try (1...3).map { index -> URL in
            let url = dir.appendingPathComponent("img\(index).png")
            try TestImages.write(TestImages.make(width: 8, height: 8), to: url, type: .png)
            return url
        }
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try files.createDirectory(at: out, withIntermediateDirectories: true)
        // Two minutes old: the run-start sweep (over an hour) keeps it, a cancel removes it. A fresh one may be
        // another process's write in progress, so it stays.
        let leftover = try makeFile(".imageconverter-\(UUID().uuidString).tmp", in: out, age: 120)
        let fresh = try makeFile(".imageconverter-\(UUID().uuidString).tmp", in: out, age: 5)
        let holder = CancelHolder()
        let task = Task {
            await BatchRunner.run(InputCollector.collect(sources), pipeline: Pipeline(output: .init(format: .jpeg)),
                                  mode: .newFolder(out), concurrency: 1, events: { event in
                                      if event.stage == .done { holder.cancel() }
                                  })
        }
        holder.store(task)
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertFalse(files.fileExists(atPath: leftover.path))
        XCTAssertEqual(tempFiles(in: out), [fresh.lastPathComponent])
        XCTAssertFalse(report.written.isEmpty)
    }
}

/// Holds a task so a callback can cancel it, even before it is stored.
private final class CancelHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<BatchReport, Never>?
    private var requested = false

    func store(_ task: Task<BatchReport, Never>) {
        lock.lock()
        self.task = task
        let cancel = requested
        lock.unlock()
        if cancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        requested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
