import CoreGraphics
import Foundation

/// The one door to the alt text model, shared by every batch (manual runs, jobs, services, scripts) and the preview.
///
/// - One model call at a time, app-wide. A call holds the turn until its task really ends, not when its item times
///   out, so a model that ignores cancellation never has more than one call running.
/// - Turns are handed out in order (first come, first served); the preview's requests go ahead of the batches' but
///   never run beside another call. Waiting for a turn has no time limit; an item's 30 s start when it gets its turn.
/// - Circuit breaker: after `tripAfterTimeouts` timeouts in a row, or while a call that timed out is still running
///   `stuckAfter` seconds after it started, the model counts as not responding. Every waiting and later request then
///   fails at once with `AltText.notResponding`, until a call answers in time (which, with no calls made while it
///   is stopped, means until the app restarts).
final class AltTextModelGate: @unchecked Sendable {
    static let shared = AltTextModelGate()

    /// What a request gets when it is its turn, or why it won't get one.
    enum Turn: Equatable, Sendable {
        case yourTurn
        case notResponding
        case cancelled
    }

    /// One request waiting for its turn; `deliver` is called exactly once.
    final class Waiter: @unchecked Sendable {
        let priority: Bool
        private let lock = NSLock()
        private var handler: (@Sendable (Turn) -> Void)?

        init(priority: Bool, handler: @escaping @Sendable (Turn) -> Void) {
            self.priority = priority
            self.handler = handler
        }

        func deliver(_ turn: Turn) {
            let handler = lock.withLock { () -> (@Sendable (Turn) -> Void)? in
                defer { self.handler = nil }
                return self.handler
            }
            handler?(turn)
        }
    }

    let tripAfterTimeouts: Int
    let stuckAfter: TimeInterval
    private static let timerQueue = DispatchQueue(label: "imageconverter.alt-text.gate")
    private let lock = NSLock()
    private var busy = false
    private var waiters: [Waiter] = []
    private var timeoutStreak = 0
    private var stopped = false
    private var calls = 0
    private var current: (id: Int, timedOut: Bool)?
    private let running = WaitingCounter()

    init(tripAfterTimeouts: Int = 3, stuckAfter: TimeInterval = 60) {
        self.tripAfterTimeouts = max(1, tripAfterTimeouts)
        self.stuckAfter = stuckAfter
    }

    /// Whether the model counts as not responding (requests fail at once).
    var isStopped: Bool { lock.withLock { stopped } }

    /// The most model calls whose task was running at once (tests).
    var peakRunning: Int { running.peak }

    /// Back to a fresh start: not stopped, no streak (tests; the turn and its waiters are left alone).
    func reset() {
        lock.withLock {
            stopped = false
            timeoutStreak = 0
        }
    }

    /// Queues `waiter`: it gets `.yourTurn` at once when nobody holds the turn, `.notResponding` at once when the model is
    /// stopped, else later, in order (priority waiters ahead of the others, in their own order).
    func enqueue(_ waiter: Waiter) {
        lock.lock()
        if stopped {
            lock.unlock()
            waiter.deliver(.notResponding)
        } else if !busy {
            busy = true
            lock.unlock()
            waiter.deliver(.yourTurn)
        } else {
            if waiter.priority {
                waiters.insert(waiter, at: waiters.firstIndex { !$0.priority } ?? waiters.count)
            } else {
                waiters.append(waiter)
            }
            lock.unlock()
        }
    }

    /// Takes `waiter` out of the queue; false when it already got its turn (the caller then holds it and must
    /// `pass()` or `call` with it).
    func withdraw(_ waiter: Waiter) -> Bool {
        lock.withLock {
            guard let index = waiters.firstIndex(where: { $0 === waiter }) else { return false }
            waiters.remove(at: index)
            return true
        }
    }

    /// Gives the turn up without calling the model.
    func pass() {
        handOff()
    }

    /// Waits (blocking the thread, in slices so a cancelled task notices) for a turn; `.cancelled` when the current
    /// task was cancelled while waiting (no turn is then held).
    func waitForTurn(priority: Bool = false) -> Turn {
        let box = TurnBox()
        let waiter = Waiter(priority: priority) { box.set($0) }
        enqueue(waiter)
        while !box.wait(seconds: 0.25) {
            if Task.isCancelled && withdraw(waiter) { return .cancelled }
        }
        return box.value ?? .cancelled
    }

    /// Waits (suspended) for a turn; `.cancelled` when the task was cancelled while waiting (no turn is then held).
    func turn(priority: Bool) async -> Turn {
        let box = TurnBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Turn, Never>) in
                let waiter = Waiter(priority: priority) { continuation.resume(returning: $0) }
                box.waiter = waiter
                if Task.isCancelled {
                    waiter.deliver(.cancelled)
                } else {
                    enqueue(waiter)
                    // A cancel between the check above and `enqueue` found nothing to withdraw: withdraw now.
                    if Task.isCancelled, withdraw(waiter) { waiter.deliver(.cancelled) }
                }
            }
        } onCancel: {
            if let waiter = box.waiter, withdraw(waiter) { waiter.deliver(.cancelled) }
        }
    }

    /// With the turn held: one model call through `run` (its timeout counts from now). `finish` gets the outcome
    /// once; the turn passes on when the call's task really ends.
    func call(_ run: AltTextRun, image: CGImage, generator: any AltTextGenerator, timeout: TimeInterval,
              finish: @escaping @Sendable (AltTextOutcome) -> Void) {
        let id = lock.withLock { () -> Int in
            calls += 1
            current = (calls, false)
            return calls
        }
        running.enter()
        Self.timerQueue.asyncAfter(deadline: .now() + max(0, stuckAfter)) { [self] in stuckCheck(id) }
        run.start(image, generator: generator, timeout: timeout, finish: { [self] outcome in
            record(outcome, call: id)
            finish(outcome)
        }, ended: { [self] in
            running.leave()
            lock.withLock { if current?.id == id { current = nil } }
            handOff()
        })
    }

    private func record(_ outcome: AltTextOutcome, call id: Int) {
        lock.lock()
        switch outcome {
        case .text:
            timeoutStreak = 0
            stopped = false
        case .failed(AltText.timedOut):
            if current?.id == id { current?.timedOut = true }
            timeoutStreak += 1
            if timeoutStreak >= tripAfterTimeouts {
                stopLocked()
                return
            }
        case .failed("cancelled"):
            // Abandoned, not answered: like a timeout for the stuck check (a hung model must still stop the gate),
            // but not counted toward the timeout streak.
            if current?.id == id { current?.timedOut = true }
        case .failed:
            timeoutStreak = 0
        }
        lock.unlock()
    }

    /// A call that timed out and is still running `stuckAfter` after it started stops the model.
    private func stuckCheck(_ id: Int) {
        lock.lock()
        if let current, current.id == id, current.timedOut {
            stopLocked()
        } else {
            lock.unlock()
        }
    }

    /// Called with the lock held; unlocks it, then tells every waiter.
    private func stopLocked() {
        stopped = true
        let told = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in told { waiter.deliver(.notResponding) }
    }

    private func handOff() {
        lock.lock()
        guard !waiters.isEmpty else {
            busy = false
            lock.unlock()
            return
        }
        // The turn passes straight to the next waiter (stopping already told and removed them all).
        let next = waiters.removeFirst()
        lock.unlock()
        next.deliver(.yourTurn)
    }
}

/// A turn handed to a blocking or suspended waiter.
private final class TurnBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var turn: AltTextModelGate.Turn?
    private var stored: AltTextModelGate.Waiter?

    var waiter: AltTextModelGate.Waiter? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func set(_ turn: AltTextModelGate.Turn) {
        lock.withLock { self.turn = turn }
        semaphore.signal()
    }

    /// True once a turn was set.
    func wait(seconds: Double) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }

    var value: AltTextModelGate.Turn? { lock.withLock { turn } }
}
