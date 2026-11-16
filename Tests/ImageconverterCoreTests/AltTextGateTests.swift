import CoreGraphics
import Foundation
import XCTest
@testable import ImageconverterCore

/// The app-wide alt text gate (`AltTextModelGate`): one call at a time, turns in order, the 30 s from the turn, the
/// circuit breaker, and the preview sharing it. Fake models only; each test has a gate of its own.
final class AltTextGateTests: XCTestCase {

    /// A model that records which image (by width) it was asked about, in order, and how many calls ran at once.
    /// `block` holds its thread and ignores cancellation (the worst case); otherwise it suspends.
    private final class Model: AltTextGenerator, @unchecked Sendable {
        let availability: AltTextAvailability = .available
        let active = ActiveCounter()
        private let lock = NSLock()
        private var widths: [Int] = []
        private let seconds: Double
        private let block: Bool

        init(seconds: Double, block: Bool) {
            self.seconds = seconds
            self.block = block
        }

        var order: [Int] { lock.withLock { widths } }

        func generate(for image: CGImage) async throws -> String {
            lock.withLock { widths.append(image.width) }
            active.enter()
            defer { active.leave() }
            if block {
                usleep(UInt32(seconds * 1_000_000))
            } else {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            return "A described image."
        }
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ line: String) { lock.withLock { all.append(line) } }
        var lines: [String] { lock.withLock { all } }
    }

    private func image(_ width: Int = 8) -> CGImage { TestImages.make(width: width, height: 8) }

    /// Runs `count` blocking calls on threads of their own (like the batch's synchronous workers), started in order a
    /// little apart, and returns their outcomes in start order.
    private func blockingCalls(_ count: Int, model: Model, timeout: TimeInterval, gate: AltTextModelGate,
                               spacing: TimeInterval = 0.02, width: (Int) -> Int = { _ in 8 }) -> [AltTextOutcome] {
        let lock = NSLock()
        var outcomes = [AltTextOutcome?](repeating: nil, count: count)
        let group = DispatchGroup()
        for index in 0..<count {
            group.enter()
            let picture = image(width(index))
            Thread.detachNewThread {
                let outcome = (try? AltText.generateBlocking(for: picture, with: model, timeout: timeout, gate: gate))
                lock.withLock { outcomes[index] = outcome }
                group.leave()
            }
            Thread.sleep(forTimeInterval: spacing)
        }
        group.wait()
        return outcomes.map { $0 ?? .failed("threw") }
    }

    /// A model that holds its thread and ignores cancellation never has a second call running beside it, and after
    /// three timeouts in a row every further item fails at once without asking it.
    func testBlockingModelRunsOneCallAtATimeAndTheBreakerTripsAfterThreeTimeouts() {
        let gate = AltTextModelGate()
        let model = Model(seconds: 0.5, block: true)
        let started = Date()
        let outcomes = blockingCalls(8, model: model, timeout: 0.1, gate: gate)
        XCTAssertEqual(model.active.peak, 1)
        XCTAssertEqual(gate.peakRunning, 1)
        XCTAssertEqual(model.order.count, 3, "only three calls reached the model")
        XCTAssertEqual(outcomes.filter { $0 == .failed(AltText.timedOut) }.count, 3)
        XCTAssertEqual(outcomes.filter { $0 == .failed(AltText.notResponding) }.count, 5)
        XCTAssertTrue(gate.isStopped)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "about three calls' time, not eight")
        XCTAssertEqual(AltTextOutcome.failed(AltText.notResponding).note,
                       "Alt text not generated: the on-device model stopped responding")
    }

    /// Turns go first come, first served; a priority (preview) request goes ahead of the waiting ones.
    func testTurnsAreHandedOutInOrderWithThePreviewFirst() {
        let gate = AltTextModelGate()
        let log = Log()
        func waiter(_ name: String, priority: Bool = false) -> AltTextModelGate.Waiter {
            AltTextModelGate.Waiter(priority: priority) { log.add("\(name):\($0)") }
        }
        gate.enqueue(waiter("holder"))
        for name in ["a", "b", "c"] { gate.enqueue(waiter(name)) }
        gate.enqueue(waiter("preview", priority: true))
        gate.enqueue(waiter("d"))
        gate.enqueue(waiter("preview2", priority: true))
        for _ in 0..<7 { gate.pass() }
        XCTAssertEqual(log.lines, ["holder", "preview", "preview2", "a", "b", "c", "d"].map { "\($0):yourTurn" })
        // The last pass freed the turn: the next request gets it at once.
        gate.enqueue(waiter("later"))
        XCTAssertEqual(log.lines.last, "later:yourTurn")
    }

    /// A slow but healthy model (0.15 s an image) with six workers waiting and a 0.5 s timeout: every item is
    /// answered, because an item's time starts at its turn, not while it queues.
    func testQueueingNeverTimesOutAHealthyModel() {
        let gate = AltTextModelGate()
        let model = Model(seconds: 0.15, block: false)
        let outcomes = blockingCalls(6, model: model, timeout: 0.5, gate: gate, spacing: 0)
        XCTAssertEqual(outcomes, Array(repeating: .text("A described image."), count: 6))
        XCTAssertEqual(model.active.peak, 1)
        XCTAssertFalse(gate.isStopped)
    }

    /// The batch's blocking waiters get their turns in the order they arrived.
    func testBlockingWaitersAreServedInArrivalOrder() {
        let gate = AltTextModelGate()
        let model = Model(seconds: 0.1, block: false)
        _ = blockingCalls(5, model: model, timeout: 5, gate: gate, spacing: 0.03) { 10 + $0 }
        XCTAssertEqual(model.order, [10, 11, 12, 13, 14])
    }

    /// Two timeouts, an answer, two timeouts: not three in a row, so the model still counts as responding.
    func testAnAnswerResetsTheTimeoutStreak() {
        let gate = AltTextModelGate()
        let slow = Model(seconds: 0.3, block: false)
        let quick = Model(seconds: 0.01, block: false)
        for _ in 0..<2 { XCTAssertEqual(try AltText.generateBlocking(for: image(), with: slow, timeout: 0.05, gate: gate),
                                        .failed(AltText.timedOut)) }
        XCTAssertEqual(try AltText.generateBlocking(for: image(), with: quick, timeout: 1, gate: gate), .text("A described image."))
        for _ in 0..<2 { XCTAssertEqual(try AltText.generateBlocking(for: image(), with: slow, timeout: 0.05, gate: gate),
                                        .failed(AltText.timedOut)) }
        XCTAssertFalse(gate.isStopped)
        XCTAssertEqual(try AltText.generateBlocking(for: image(), with: slow, timeout: 0.05, gate: gate),
                       .failed(AltText.timedOut))
        XCTAssertTrue(gate.isStopped)
        gate.reset()
        XCTAssertEqual(try AltText.generateBlocking(for: image(), with: quick, timeout: 1, gate: gate), .text("A described image."))
    }

    /// A call that timed out and is still running past `stuckAfter` (60 s in the app) stops the model: the item
    /// waiting behind it fails then, instead of waiting for the hung call.
    func testAHungCallPastTheStuckLimitStopsTheModel() {
        let gate = AltTextModelGate(stuckAfter: 0.5)
        let model = Model(seconds: 1.5, block: true)
        let started = Date()
        let outcomes = blockingCalls(2, model: model, timeout: 0.1, gate: gate, spacing: 0.2)
        XCTAssertEqual(outcomes, [.failed(AltText.timedOut), .failed(AltText.notResponding)])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.3, "didn't wait for the hung call to end")
        XCTAssertEqual(model.order.count, 1)
        XCTAssertTrue(gate.isStopped)
    }

    /// A call abandoned before its timeout (the preview's selection changed, a batch was cancelled) on a model that
    /// hangs still counts for the stuck limit: the next item gets "not responding" instead of waiting for the hang.
    func testACancelledHungCallStillStopsTheModel() async throws {
        let gate = AltTextModelGate(tripAfterTimeouts: 3, stuckAfter: 0.5)
        let model = Model(seconds: 3, block: true)
        let picture = image()
        let preview = Task { await AltText.generate(for: picture, with: model, timeout: 0.3, gate: gate) }
        try await Task.sleep(nanoseconds: 100_000_000)
        preview.cancel()
        _ = await preview.value
        let started = Date()
        let next = try AltText.generateBlocking(for: picture, with: model, timeout: 0.3, gate: gate)
        XCTAssertEqual(next, .failed(AltText.notResponding))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "didn't wait for the hung call to end")
        XCTAssertTrue(gate.isStopped)
    }

    /// The preview goes through the same gate: never beside a batch call, and ahead of the batch's waiting items.
    func testThePreviewSharesTheGateAndGoesAheadOfWaitingItems() async {
        let gate = AltTextModelGate()
        let model = Model(seconds: 0.3, block: true)
        let batch = Task.detached { [self] in
            blockingCalls(2, model: model, timeout: 5, gate: gate, spacing: 0.05) { 10 + $0 }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let preview = await AltText.generate(for: image(30), with: model, timeout: 5, gate: gate)
        let outcomes = await batch.value
        XCTAssertEqual(preview, .text("A described image."))
        XCTAssertEqual(outcomes, Array(repeating: .text("A described image."), count: 2))
        XCTAssertEqual(model.active.peak, 1)
        XCTAssertEqual(model.order, [10, 30, 11])
    }

    func testThePreviewSaysTheModelStoppedResponding() async {
        let gate = AltTextModelGate(tripAfterTimeouts: 1)
        let model = Model(seconds: 0.3, block: false)
        XCTAssertEqual(try AltText.generateBlocking(for: image(), with: model, timeout: 0.05, gate: gate),
                       .failed(AltText.timedOut))
        let preview = await AltText.generate(for: image(), with: model, timeout: 5, gate: gate)
        XCTAssertEqual(preview, .failed(AltText.notResponding))
    }

    /// A batch cancelled while its worker waits for the turn stops waiting at once and leaves no turn held.
    func testCancelWhileWaitingForTheTurnStopsAndHoldsNothing() async throws {
        let gate = AltTextModelGate()
        let holder = AltTextModelGate.Waiter(priority: false) { _ in }
        gate.enqueue(holder)
        let picture = image()
        let model = Model(seconds: 0.01, block: false)
        let task = Task.detached { () -> Result<AltTextOutcome, Error> in
            Result { try AltText.generateBlocking(for: picture, with: model, timeout: 5, gate: gate) }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = Date()
        task.cancel()
        let result = await task.value
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        gate.pass()
        XCTAssertEqual(try AltText.generateBlocking(for: picture, with: model, timeout: 5, gate: gate), .text("A described image."))
        XCTAssertEqual(model.order.count, 1, "the cancelled worker never called the model")
    }
}
