import XCTest
@testable import ImageconverterCore

private final class FakeClock: @unchecked Sendable {
    var now: TimeInterval = 0
}

final class RunMetricsTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/a.jpg")

    private func done(_ index: Int, input: Int = 1000, output: Int = 400) -> ItemEvent {
        ItemEvent(index: index, source: url, stage: .done, inputBytes: input, outputBytes: output, duration: 1)
    }

    func testETAFromPixelsThroughput() {
        let clock = FakeClock()
        // Item 0..3 are 1 MP each and finish one per second; the six left are 10 MP each.
        var metrics = RunMetrics(sourcePixels: Array(repeating: 1_000_000, count: 4)
            + Array(repeating: 10_000_000, count: 6)) { clock.now }
        for index in 0..<4 {
            clock.now += 1
            metrics.record(done(index))
        }
        let snap = metrics.snapshot()
        XCTAssertEqual(snap.megapixelsPerSecond, 1.05, accuracy: 0.1)
        // 60 MP left at about 1 MP/s, not 6 items at 1 image/s.
        XCTAssertEqual(try XCTUnwrap(snap.eta), 57, accuracy: 6)
        XCTAssertEqual(snap.savingPercent ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(snap.inputBytes, 4000)
        XCTAssertEqual(snap.outputBytes, 1600)
    }

    func testETANilUntilThreeItems() {
        let clock = FakeClock()
        var metrics = RunMetrics(sourcePixels: Array(repeating: 1_000_000, count: 5)) { clock.now }
        XCTAssertNil(metrics.snapshot().eta)
        for index in 0..<2 {
            clock.now += 1
            metrics.record(done(index))
            XCTAssertNil(metrics.snapshot().eta)
        }
        clock.now += 1
        metrics.record(done(2))
        XCTAssertNotNil(metrics.snapshot().eta)
    }

    func testThroughputMovingAverage() {
        let clock = FakeClock()
        var metrics = RunMetrics(sourcePixels: Array(repeating: 1_000_000, count: 100)) { clock.now }
        // A fast start (2 images/s), then a long slow stretch (1 image per 5 s): the average follows the recent pace.
        var index = 0
        for _ in 0..<20 {
            clock.now += 0.5
            metrics.record(done(index)); index += 1
        }
        let fast = metrics.snapshot().imagesPerSecond
        XCTAssertEqual(fast, 2, accuracy: 0.3)
        for _ in 0..<12 {
            clock.now += 5
            metrics.record(done(index)); index += 1
        }
        let slow = metrics.snapshot().imagesPerSecond
        XCTAssertEqual(slow, 0.2, accuracy: 0.1)
        // Idle time lowers it further without any event.
        clock.now += 30
        XCTAssertLessThan(metrics.snapshot().imagesPerSecond, slow / 2)
    }

    func testFailuresCountAsFinishedNotDone() {
        let clock = FakeClock()
        var metrics = RunMetrics(sourcePixels: [1, 1, 1]) { clock.now }
        clock.now = 1
        metrics.record(ItemEvent(index: 0, source: url, stage: .failed("x"), inputBytes: 10))
        metrics.record(ItemEvent(index: 0, source: url, stage: .failed("x"), inputBytes: 10))
        let snap = metrics.snapshot()
        XCTAssertEqual(snap.imagesDone, 0)
        XCTAssertEqual(snap.imagesFinished, 1)
        XCTAssertNil(snap.savingPercent)
    }

    func testSamplerReturnsPlausibleValues() throws {
        let sampler = ResourceSampler()
        let start = Date()
        while Date().timeIntervalSince(start) < 0.2 { _ = (0..<1000).reduce(0, +) }
        let sample = try XCTUnwrap(sampler.sample())
        XCTAssertGreaterThan(sample.memoryBytes, 1_000_000)
        XCTAssertLessThan(sample.memoryBytes, 1 << 42)
        XCTAssertGreaterThanOrEqual(sample.cpuPercent, 0)
        XCTAssertLessThanOrEqual(sample.cpuPercent, 100)
    }
}
