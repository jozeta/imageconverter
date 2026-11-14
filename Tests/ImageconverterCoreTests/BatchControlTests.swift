import XCTest
@testable import ImageconverterCore

/// Counts how many workers are inside the encode hook at once.
private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0

    func enter() {
        lock.lock()
        current += 1
        peak = max(peak, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    var maximum: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

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

final class BatchControlTests: XCTestCase {
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

    func testPauseStopsNewItemsResumeContinues() async throws {
        let urls = try files(4)
        let control = BatchControl()
        let log = LockedLog<ItemEvent>()
        let task = Task {
            await BatchRunner.run(InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out), concurrency: 1,
                                  control: control, events: { event in
                                      log.append(event)
                                      // Paused from the collector, before it starts the next item.
                                      if event.stage == .done, event.index == 0 { control.pause() }
                                  })
        }
        // Wait for the first item to finish and the pause to take hold.
        for _ in 0..<200 where !control.isPaused { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(control.isPaused)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(decodeOrder(log), ["img01.png"], "No new item may start while paused")
        control.resume()
        let report = await task.value
        XCTAssertEqual(report.written.count, 4)
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(decodeOrder(log).count, 4)
    }

    func testCancelWhilePausedEndsTheRun() async throws {
        let urls = try files(3)
        let control = BatchControl()
        control.pause()
        let task = Task {
            await BatchRunner.run(InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out), control: control)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.written.isEmpty)
    }

    func testPrioritizeMovesItemsForward() async throws {
        let urls = try files(5)
        let control = BatchControl()
        control.prioritize([urls[3]])
        let log = LockedLog<ItemEvent>()
        let report = await BatchRunner.run(
            InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out), concurrency: 1, control: control,
            events: { event in
                log.append(event)
                // Mid-run: the last file jumps ahead of the ones still waiting.
                if event.stage == .done, event.source == urls[3] { control.prioritize([urls[4]]) }
            })
        XCTAssertEqual(report.written.count, 5)
        XCTAssertEqual(decodeOrder(log), ["img04.png", "img05.png", "img01.png", "img02.png", "img03.png"])
        // The report stays in input order.
        XCTAssertEqual(report.order, urls)
    }

    func testEventsStageOrder() async throws {
        let urls = try files(1)
        let broken = root.appendingPathComponent("src/broken.png")
        try Data("not an image".utf8).write(to: broken)
        let log = LockedLog<ItemEvent>()
        let progress = LockedLog<BatchProgress>()
        let items = InputCollector.collect(urls + [broken])
        let report = await BatchRunner.run(items, pipeline: jpeg,
                                           mode: .newFolder(out), progress: { progress.append($0) },
                                           events: { log.append($0) })
        XCTAssertEqual(report.written.count, 1)
        let good = log.values.filter { $0.source == urls[0] }
        XCTAssertEqual(good.map(\.stage), [.queued, .decoding, .processing, .encoding, .writing, .done])
        let goodIndex = try XCTUnwrap(items.firstIndex { $0.source == urls[0] })
        XCTAssertTrue(good.allSatisfy { $0.index == goodIndex })
        let done = try XCTUnwrap(good.last)
        XCTAssertEqual(done.inputBytes, BatchRunner.fileSize(urls[0]))
        XCTAssertEqual(done.outputBytes, report.entries.first?.outputBytes)
        XCTAssertNotNil(done.duration)
        let bad = log.values.filter { $0.source == broken }
        XCTAssertEqual(bad.map(\.stage), [.queued, .decoding, .failed(ConversionError.unreadable.reason)])
        XCTAssertTrue(bad.allSatisfy { $0.index == 1 - goodIndex })
        XCTAssertEqual(progress.last, BatchProgress(completed: 2, failed: 1, total: 2))
    }

    func testSkippedItemsGetASkippedEvent() async throws {
        let urls = try files(2)
        var pipeline = jpeg
        let skip = ConditionalStep(conditions: [.longestEdge(.greaterThan, 1)], then: [.skip])
        pipeline.steps = [PipelineStep(operation: .condition(skip))]
        let log = LockedLog<ItemEvent>()
        let report = await BatchRunner.run(InputCollector.collect(urls), pipeline: pipeline, mode: .newFolder(out),
                                           events: { log.append($0) })
        XCTAssertEqual(report.skipped.count, 2)
        XCTAssertEqual(log.values.map(\.stage), [.skipped, .skipped])
        XCTAssertEqual(log.values.map(\.index), [0, 1])
    }

    func testLowMemoryLimitsConcurrency() async throws {
        let urls = try files(8)
        let probe = ConcurrencyProbe()
        var hooks = BatchHooks()
        hooks.beforeEncode = { _, _ in
            probe.enter()
            Thread.sleep(forTimeInterval: 0.05)
            probe.leave()
        }
        let control = BatchControl()
        control.setLowMemory(true)
        let report = await BatchRunner.run(InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out),
                                           concurrency: 8, control: control, hooks: hooks)
        XCTAssertEqual(report.written.count, 8)
        XCTAssertLessThanOrEqual(probe.maximum, 2)

        // Without low-memory mode the same batch does run wider (sanity check of the probe).
        let wide = ConcurrencyProbe()
        hooks.beforeEncode = { _, _ in
            wide.enter()
            Thread.sleep(forTimeInterval: 0.05)
            wide.leave()
        }
        let second = await BatchRunner.run(InputCollector.collect(urls), pipeline: jpeg,
                                           mode: .newFolder(root.appendingPathComponent("out2")), concurrency: 8,
                                           hooks: hooks)
        XCTAssertEqual(second.written.count, 8)
        if ProcessInfo.processInfo.activeProcessorCount >= 4 { XCTAssertGreaterThan(wide.maximum, 2) }
    }

    func testCriticalMemoryPressureRunsOneAtATime() async throws {
        let urls = try files(6)
        let probe = ConcurrencyProbe()
        var hooks = BatchHooks()
        hooks.memoryPressure = { .critical }
        hooks.beforeEncode = { _, _ in
            probe.enter()
            Thread.sleep(forTimeInterval: 0.03)
            probe.leave()
        }
        let report = await BatchRunner.run(InputCollector.collect(urls), pipeline: jpeg, mode: .newFolder(out),
                                           concurrency: 8, hooks: hooks)
        XCTAssertEqual(report.written.count, 6)
        XCTAssertEqual(probe.maximum, 1)
    }

    func testLimitsFollowThermalStateMemoryPressureAndLowMemory() {
        func limits(_ thermal: ProcessInfo.ThermalState, _ pressure: MemoryPressure = .normal,
                    lowMemory: Bool = false, retrying: Bool = false) -> BatchLimits {
            BatchLimits.effective(concurrency: 8, budget: 1000, conditions: BatchConditions(
                thermal: thermal, pressure: pressure, lowMemory: lowMemory, retrying: retrying))
        }
        XCTAssertEqual(limits(.nominal), BatchLimits(maxItems: 8, maxWeight: 1000))
        XCTAssertEqual(limits(.fair), BatchLimits(maxItems: 8, maxWeight: 1000))
        XCTAssertEqual(limits(.serious), BatchLimits(maxItems: 4, maxWeight: 1000))
        XCTAssertEqual(limits(.critical), BatchLimits(maxItems: 1, maxWeight: 1000))
        XCTAssertEqual(limits(.nominal, .warning), BatchLimits(maxItems: 8, maxWeight: 500))
        XCTAssertEqual(limits(.nominal, .critical).maxItems, 1)
        XCTAssertEqual(limits(.nominal, lowMemory: true), BatchLimits(maxItems: 2, maxWeight: 250))
        XCTAssertEqual(limits(.serious, .warning, lowMemory: true), BatchLimits(maxItems: 2, maxWeight: 125))
        XCTAssertEqual(limits(.nominal, retrying: true).maxItems, 1)
        let tiny = BatchConditions(thermal: .serious, pressure: .warning, lowMemory: true)
        XCTAssertEqual(BatchLimits.effective(concurrency: 1, budget: 1, conditions: tiny),
                       BatchLimits(maxItems: 1, maxWeight: 1))
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
        XCTAssertFalse(ConversionError.unreadable.isRetryable)
        XCTAssertFalse(ConversionError.sizeUnreachable(limit: 1, smallest: 2).isRetryable)
        XCTAssertFalse(ConversionError.watermarkImageUnreadable.isRetryable)
        XCTAssertFalse(ConversionError.watermarkSVGUnsafe.isRetryable)
        XCTAssertFalse(ConversionError.tooLarge(pixels: 1).isRetryable)
        XCTAssertFalse(ConversionError.writeFailed("x").isRetryable)
    }

    func testSharedCIContextIsOneInstance() {
        XCTAssertTrue(SharedCIContext.context === SharedCIContext.context)
        XCTAssertNotNil(SharedCIContext.context.workingColorSpace)
    }
}
