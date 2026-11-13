import XCTest
@testable import ImageconverterCore

/// Holds a task so a progress callback can cancel it, even if the callback runs before it is stored.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<BatchReport, Never>?
    private var cancelRequested = false

    func store(_ task: Task<BatchReport, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

final class BatchRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testConvertsAndSkipsBrokenFiles() async throws {
        let src = try directory("src")
        let out = root.appendingPathComponent("out", isDirectory: true)
        var files: [URL] = []
        for index in 1...5 {
            let url = src.appendingPathComponent("img\(index).png")
            try TestImages.write(TestImages.make(width: 20, height: 20), to: url, type: .png)
            files.append(url)
        }
        let broken = src.appendingPathComponent("broken.jpg")
        try Data().write(to: broken)
        files.append(broken)

        let items = InputCollector.collect(files)
        let log = LockedLog<BatchProgress>()
        let report = await BatchRunner.run(items, output: .init(format: .jpeg), mode: .newFolder(out),
                                           progress: { log.append($0) })

        XCTAssertEqual(report.written.count, 5)
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.failures.map(\.source.lastPathComponent), ["broken.jpg"])
        XCTAssertEqual(report.failures.first?.reason, ConversionError.unreadable.reason)
        XCTAssertEqual(log.last, BatchProgress(completed: 6, failed: 1, total: 6))
        XCTAssertEqual(log.values.map(\.completed), Array(1...6))
        for url in report.written { XCTAssertNoThrow(try ImageLoader.load(url)) }
    }

    func testCancelKeepsFinishedFilesAndLeavesNoTemps() async throws {
        let src = try directory("src")
        let out = root.appendingPathComponent("out", isDirectory: true)
        let image = TestImages.noise(width: 1500, height: 1500)
        var files: [URL] = []
        for index in 0..<40 {
            let url = src.appendingPathComponent(String(format: "n%02d.png", index))
            try TestImages.write(image, to: url, type: .png)
            files.append(url)
        }
        let items = files.map { InputItem(source: $0, relativeDirectory: "") }

        let box = TaskBox()
        let task = Task {
            await BatchRunner.run(items, output: .init(format: .jpeg), mode: .newFolder(out),
                                  concurrency: 2, progress: { _ in box.cancel() })
        }
        box.store(task)
        let report = await task.value

        XCTAssertTrue(report.cancelled)
        XCTAssertGreaterThan(report.written.count, 0)
        XCTAssertLessThan(report.written.count, 40)
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(names.filter { $0.hasPrefix(FileCommitter.tempPrefix) }, [])
        XCTAssertEqual(Set(names).count, report.written.count)
    }

    func testOverwriteFormatChangeTrashesOriginals() async throws {
        let src = try directory("src")
        let original = src.appendingPathComponent("a.heic")
        // Content sniffing decodes this regardless of the extension.
        try TestImages.write(TestImages.make(width: 10, height: 10), to: original, type: .png)

        let trashed = LockedLog<URL>()
        let trash: Trasher = { trashed.append($0) }
        let report = await BatchRunner.run(
            InputCollector.collect([original]), output: .init(format: .jpeg), mode: .overwrite, trash: trash)

        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written, [src.appendingPathComponent("a.jpg")])
        XCTAssertEqual(trashed.values, [original])
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.jpg").path))
    }
}
