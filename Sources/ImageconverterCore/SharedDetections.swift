import Foundation

/// The kept results and the detections in progress behind `FocusCache` and `RedactCache`, so the preview, the
/// size estimate and the quality ladder asking for one detection at once share one run (bug F2: two or three
/// Vision passes over one 48 MP image took 5.3 or 8.2 s instead of 2.9 s).
///
/// Each detection runs in a task of its own (off the cooperative pool on macOS 15, `DetectionExecutor`), not on
/// the first caller's thread, so no single caller's cancellation stops it: a cancelled caller stops waiting at once.
/// When every caller waiting for it was cancelled, the detection keeps running for `grace` (2 s), because an edit or a
/// reselection cancels a render only to ask for the same detection again 300 ms later; a lookup in that time joins it.
/// Only a detection nobody joined by then is cancelled. Results `keep` rejects (failures, cancellations) reach every
/// caller waiting for them and aren't kept, so the next lookup detects again.
final class SharedDetections<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private final class Flight {
        var waiters = 0
        /// Counts the times every waiter left, so a grace timer only acts on the abandonment it was set for.
        var abandonments = 0
        var result: Value?
        var task: Task<Void, Never>?
    }

    /// How often a waiter looks at its own cancellation.
    private static var cancellationCheck: TimeInterval { 0.02 }

    private let lock = NSCondition()
    private var entries: [Key: Value] = [:]
    private var flights: [Key: Flight] = [:]
    private let limit: Int
    private let keep: @Sendable (Value) -> Bool
    private let grace: TimeInterval
    private var runs = 0

    /// How long a detection every waiter left keeps running for a new one.
    static var defaultGrace: TimeInterval { 2 }

    init(limit: Int, grace: TimeInterval = defaultGrace, keep: @escaping @Sendable (Value) -> Bool) {
        self.limit = max(1, limit)
        self.grace = max(0, grace)
        self.keep = keep
    }

    /// How many detections ran.
    var runCount: Int { lock.withLock { runs } }

    /// How many callers wait for a detection right now (for tests).
    var waiterCount: Int { lock.withLock { flights.values.reduce(0) { $0 + $1.waiters } } }

    /// Forgets the kept results and cancels the detections nobody waits for (`cancelIdle`).
    func removeAll() {
        lock.withLock { entries = [:] }
        cancelIdle()
    }

    /// Cancels the detections nobody waits for (those in their grace period), so a batch start (the preview's
    /// purge) leaves no Vision pass running for nothing. Detections callers still wait for go on.
    func cancelIdle() {
        lock.withLock {
            for (key, flight) in flights where flight.waiters == 0 {
                flight.task?.cancel()
                flights[key] = nil
            }
        }
    }

    /// The kept result for `key`, else the result of the detection in progress for it (started with `detect` when
    /// none is). `waiting` is called before the caller waits for a detection, and once more (false) when it stops.
    /// Nil when the caller was cancelled before the result came.
    func value(for key: Key, waiting: ((Bool) -> Void)? = nil,
               detect: @escaping @Sendable () -> Value) -> Value? {
        lock.lock()
        if let kept = entries[key] {
            lock.unlock()
            return kept
        }
        let flight = flights[key] ?? start(key, detect: detect)
        flight.waiters += 1
        lock.unlock()
        waiting?(true)
        defer { waiting?(false) }

        lock.lock()
        defer { lock.unlock() }
        while flight.result == nil {
            if Task.isCancelled {
                flight.waiters -= 1
                if flight.waiters == 0 { abandon(flight, for: key) }
                return nil
            }
            _ = lock.wait(until: Date().addingTimeInterval(Self.cancellationCheck))
        }
        flight.waiters -= 1
        return flight.result
    }

    /// Every waiter left `flight`: cancel it after the grace period unless a new waiter joined. Called with the lock held.
    private func abandon(_ flight: Flight, for key: Key) {
        flight.abandonments += 1
        let abandonment = flight.abandonments
        let cancel = { [self] in
            lock.withLock {
                guard flight.waiters == 0, flight.abandonments == abandonment, flight.result == nil else { return }
                flight.task?.cancel()
                // The next lookup starts afresh.
                if flights[key] === flight { flights[key] = nil }
            }
        }
        if grace == 0 {
            flight.task?.cancel()
            if flights[key] === flight { flights[key] = nil }
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace, execute: cancel)
        }
    }

    /// A new flight for `key`, its detection started. Called with the lock held.
    private func start(_ key: Key, detect: @escaping @Sendable () -> Value) -> Flight {
        let flight = Flight()
        flights[key] = flight
        let finish: @Sendable () -> Void = { [self] in
            let value = detect()
            lock.lock()
            defer { lock.unlock() }
            runs += 1
            flight.result = value
            if flights[key] === flight { flights[key] = nil }
            if keep(value) {
                if entries.count >= limit { entries = [:] }
                entries[key] = value
            }
            lock.broadcast()
        }
        // The preview waits for it, whoever started it.
        if #available(macOS 15, *) {
            flight.task = Task(executorPreference: DetectionExecutor.shared, priority: .userInitiated) { finish() }
        } else {
            flight.task = Task.detached(priority: .userInitiated) { finish() }
        }
        return flight
    }
}

/// Runs the shared detections on a queue of their own instead of the cooperative pool, whose threads the waiting
/// callers (the preview, the estimate, the ladder) hold while they wait.
@available(macOS 15, *)
final class DetectionExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = DetectionExecutor()
    private let queue = DispatchQueue(label: "imageconverter.detection", qos: .userInitiated, attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}
