import Foundation

/// The kept results and the detections in progress behind `FocusCache` and `RedactCache`, so the preview, the
/// size estimate and the quality ladder asking for one detection at once share one run (bug F2: two or three
/// Vision passes over one 48 MP image took 5.3 or 8.2 s instead of 2.9 s).
///
/// Each detection runs in a task of its own (off the cooperative pool on macOS 15, `DetectionExecutor`), not on
/// the first caller's thread, so no single caller's cancellation stops it: a cancelled caller stops waiting at once,
/// and the detection is cancelled only when every caller waiting for it was. Results `keep` rejects (failures,
/// cancellations) reach every caller waiting for them and aren't kept, so the next lookup detects again.
final class SharedDetections<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private final class Flight {
        var waiters = 0
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
    private var runs = 0

    init(limit: Int, keep: @escaping @Sendable (Value) -> Bool) {
        self.limit = max(1, limit)
        self.keep = keep
    }

    /// How many detections ran.
    var runCount: Int { lock.withLock { runs } }

    func removeAll() {
        lock.withLock { entries = [:] }
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
                if flight.waiters == 0 {
                    // Nobody wants it any more: stop it, and let the next lookup start afresh.
                    flight.task?.cancel()
                    if flights[key] === flight { flights[key] = nil }
                }
                return nil
            }
            _ = lock.wait(until: Date().addingTimeInterval(Self.cancellationCheck))
        }
        flight.waiters -= 1
        return flight.result
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
        let priority = Task.currentPriority
        if #available(macOS 15, *) {
            flight.task = Task(executorPreference: DetectionExecutor.shared, priority: priority) { finish() }
        } else {
            flight.task = Task.detached(priority: priority) { finish() }
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
