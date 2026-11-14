import XCTest
@testable import ImageconverterCore

/// Fails the first encode of one file, then lets it through.
private final class FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    let name: String

    init(name: String) { self.name = name }

    func check(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard url.lastPathComponent == name, !failed else { return }
        failed = true
        throw ConversionError.encodeFailed
    }
}

/// The end-of-batch retry: which failures are retried, how they are counted and ordered.
final class BatchRetryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func files(_ count: Int) throws -> [URL] {
        let src = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        return try (1...count).map { index in
            let url = src.appendingPathComponent(String(format: "img%02d.png", index))
            try TestImages.write(TestImages.make(width: 24, height: 16), to: url, type: .png)
            return url
        }
    }

    private var out: URL { root.appendingPathComponent("out", isDirectory: true) }
    private let jpeg = Pipeline(output: .init(format: .jpeg))

    private func decodeOrder(_ log: LockedLog<ItemEvent>) -> [String] {
        log.values.filter { $0.stage == .decoding }.map(\.source.lastPathComponent)
    }

    func testRetrySucceedsOnTransientFailure() async throws {
        let urls = try files(3)
        let failing = FailOnce(name: "img02.png")
        let attempts = LockedLog<Int>()
        var hooks = BatchHooks()
        hooks.beforeEncode = { url, attempt in
            if url.lastPathComponent == "img02.png" { attempts.append(attempt) }
            try failing.check(url)
        }
        let log = LockedLog<ItemEvent>()
        let progress = LockedLog<BatchProgress>()
        let report = await BatchRunner.run(InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out),
                                           hooks: hooks, progress: { progress.append($0) },
                                           events: { log.append($0) })
        XCTAssertEqual(report.written.count, 3)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(attempts.values, [1, 2])
        XCTAssertEqual(report.notes, [BatchNote(source: urls[1], text: BatchRunner.retriedNote)])
        XCTAssertEqual(report.order, urls)
        let stages = log.values.filter { $0.source == urls[1] }.map(\.stage)
        XCTAssertEqual(stages.first, .queued)
        XCTAssertEqual(stages.last, .done)
        XCTAssertFalse(stages.contains { if case .failed = $0 { return true } else { return false } })
        XCTAssertEqual(progress.last, BatchProgress(completed: 3, failed: 0, total: 3))
    }

    func testPermanentFailuresAreNotRetried() async throws {
        let urls = try files(1)
        let attempts = LockedLog<Int>()
        var hooks = BatchHooks()
        hooks.beforeEncode = { _, attempt in
            attempts.append(attempt)
            throw ConversionError.sizeUnreachable(limit: 1, smallest: 2)
        }
        let report = await BatchRunner.run(InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out),
                                           hooks: hooks)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(attempts.values, [1])
    }

    func testRetryThatFailsAgainIsReportedOnce() async throws {
        let urls = try files(1)
        var hooks = BatchHooks()
        hooks.beforeEncode = { _, _ in throw ConversionError.encodeFailed }
        let progress = LockedLog<BatchProgress>()
        let report = await BatchRunner.run(InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out),
                                           hooks: hooks, progress: { progress.append($0) })
        XCTAssertEqual(report.failures.map(\.reason), [ConversionError.encodeFailed.reason])
        XCTAssertEqual(progress.values, [BatchProgress(completed: 1, failed: 1, total: 1)])
    }

    func testRetryableErrors() {
        XCTAssertTrue(ConversionError.encodeFailed.isRetryable)
        XCTAssertTrue(ConversionError.decodeFailed.isRetryable)
        XCTAssertTrue(ConversionError.processingFailed("Adjust").isRetryable)
        XCTAssertFalse(ConversionError.processingFailed(StepKind.watermark.displayName).isRetryable)
        XCTAssertFalse(ConversionError.unreadable.isRetryable)
        XCTAssertFalse(ConversionError.sizeUnreachable(limit: 1, smallest: 2).isRetryable)
        XCTAssertFalse(ConversionError.watermarkImageUnreadable.isRetryable)
        XCTAssertFalse(ConversionError.watermarkSVGUnsafe.isRetryable)
        XCTAssertFalse(ConversionError.tooLarge(pixels: 1).isRetryable)
        XCTAssertFalse(ConversionError.writeFailed("x").isRetryable)
    }

    func testPrioritizeMovesRetryItemsToTheFrontOfTheRetryPass() async throws {
        let urls = try files(4)
        let control = BatchControl()
        var hooks = BatchHooks()
        // Every file fails once, so all four wait for the retry pass.
        let failing = urls.map { FailOnce(name: $0.lastPathComponent) }
        hooks.beforeEncode = { url, _ in try failing.first { $0.name == url.lastPathComponent }?.check(url) }
        let log = LockedLog<ItemEvent>()
        let report = await BatchRunner.run(
            InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out), concurrency: 1, control: control,
            hooks: hooks, events: { event in
                log.append(event)
                // Asked for while the last file is waiting for its retry.
                if event.stage == .queued, event.source == urls[3],
                   log.values.contains(where: { $0.stage == .decoding && $0.source == urls[3] }) {
                    control.prioritize([urls[3]])
                }
            })
        XCTAssertEqual(report.written.count, 4)
        let order = decodeOrder(log)
        XCTAssertEqual(Array(order.suffix(4)), ["img04.png", "img01.png", "img02.png", "img03.png"])
    }

    func testRetryableFailureCancelledBeforeItsRetryIsCounted() async throws {
        let urls = try files(2)
        let box = TaskHolder()
        var hooks = BatchHooks()
        hooks.beforeEncode = { url, _ in
            guard url.lastPathComponent == "img01.png" else { return }
            throw ConversionError.encodeFailed
        }
        let progress = LockedLog<BatchProgress>()
        let log = LockedLog<ItemEvent>()
        let task = Task {
            await BatchRunner.run(InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out), concurrency: 1,
                                  hooks: hooks, progress: { progress.append($0) }, events: { event in
                                      log.append(event)
                                      // Cancel once the first file is waiting for its retry.
                                      if event.stage == .queued, event.source == urls[0],
                                         log.values.contains(where: { $0.stage == .decoding }) { box.cancel() }
                                  })
        }
        box.store(task)
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.failures.map(\.source), [urls[0]])
        XCTAssertEqual(progress.last?.failed, 1)
        XCTAssertEqual(progress.last?.completed, report.failures.count + report.written.count)
        XCTAssertEqual(log.values.filter { $0.source == urls[0] }.last?.stage, .failed(ConversionError.encodeFailed.reason))
    }
}

/// Holds a task so a callback can cancel it, even if the callback runs before it is stored.
private final class TaskHolder: @unchecked Sendable {
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
