import XCTest
@testable import ImageconverterCore

final class RunStatusTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/tmp/a.jpg")
    private let second = URL(fileURLWithPath: "/tmp/b.jpg")

    private func event(_ index: Int, _ stage: ItemEvent.Stage) -> ItemEvent {
        ItemEvent(index: index, source: index == 0 ? first : second, stage: stage)
    }

    func testStageMapping() {
        XCTAssertEqual(ItemStage(.queued), .queued)
        XCTAssertEqual(ItemStage(.decoding), .decoding)
        XCTAssertEqual(ItemStage(.writing), .writing)
        XCTAssertEqual(ItemStage(.failed("Broken")), .failed)
        XCTAssertEqual(ItemStage(.skipped), .skipped)
        XCTAssertEqual(ItemStage(.cancelled), .cancelled)
        XCTAssertTrue(ItemStage.encoding.isWorking)
        XCTAssertFalse(ItemStage.done.isWorking)
        XCTAssertFalse(ItemStage.queued.isWorking)
        XCTAssertEqual(ItemStage.processing.ring, .working)
        XCTAssertEqual(ItemStage.cancelled.ring, .queued)
    }

    func testTrackerCountsWorkers() {
        var tracker = ItemStageTracker()
        tracker.record(event(0, .queued))
        tracker.record(event(1, .queued))
        XCTAssertEqual(tracker.workersInUse, 0)
        tracker.record(event(0, .decoding))
        tracker.record(event(1, .decoding))
        XCTAssertEqual(tracker.workersInUse, 2)
        // Moving between working stages keeps the count.
        tracker.record(event(0, .encoding))
        XCTAssertEqual(tracker.workersInUse, 2)
        tracker.record(event(0, .done))
        XCTAssertEqual(tracker.workersInUse, 1)
        tracker.record(event(1, .failed("x")))
        XCTAssertEqual(tracker.workersInUse, 0)
        XCTAssertEqual(tracker.stage(for: first), .done)
        XCTAssertEqual(tracker.stage(for: second), .failed)
        XCTAssertNil(tracker.stage(for: URL(fileURLWithPath: "/tmp/other.jpg")))
    }

    func testTrackerRetryGoesBackToQueued() {
        var tracker = ItemStageTracker()
        tracker.record(event(0, .decoding))
        tracker.record(event(0, .queued))
        XCTAssertEqual(tracker.workersInUse, 0)
        XCTAssertEqual(tracker.stage(for: first), .queued)
    }

    func testTrackerStopsWorkersOnFinish() {
        var tracker = ItemStageTracker()
        tracker.record(event(0, .decoding))
        tracker.finishRun()
        XCTAssertEqual(tracker.workersInUse, 0)
        // An item still marked working when the run ended didn't finish.
        XCTAssertEqual(tracker.stage(for: first), .cancelled)
    }

    func testETAPhrases() {
        XCTAssertEqual(RunStatusText.eta(nil), "estimating time left")
        XCTAssertEqual(RunStatusText.eta(0), "almost done")
        XCTAssertEqual(RunStatusText.eta(40), "less than a minute left")
        XCTAssertEqual(RunStatusText.eta(130), "about 2 min left")
        XCTAssertEqual(RunStatusText.eta(3 * 3600 + 20 * 60), "about 3 h 20 min left")
    }

    func testProgressLine() {
        XCTAssertEqual(RunStatusText.progress(completed: 12, total: 124, imagesPerSecond: 3.42, eta: 130, paused: false),
                       "12 / 124 · 3.4 img/s · about 2 min left")
        XCTAssertEqual(RunStatusText.progress(completed: 12, total: 124, imagesPerSecond: 3.4, eta: 130, paused: true),
                       "12 / 124 · paused")
        // No rate yet: just the counts and the estimate phrase.
        XCTAssertEqual(RunStatusText.progress(completed: 0, total: 5, imagesPerSecond: 0, eta: nil, paused: false),
                       "0 / 5 · estimating time left")
    }

    func testElapsedAndRates() {
        XCTAssertEqual(RunStatusText.elapsed(5), "0:05")
        XCTAssertEqual(RunStatusText.elapsed(125), "2:05")
        XCTAssertEqual(RunStatusText.elapsed(3725), "1:02:05")
        XCTAssertEqual(RunStatusText.rate(2.345, unit: "MP/s"), "2.3 MP/s")
        XCTAssertEqual(RunStatusText.percent(41.6), "42 %")
    }
}
