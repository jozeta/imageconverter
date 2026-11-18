import Foundation

/// What a caller waiting for a job's run (the Run Job Shortcuts action) is told.
public enum RunWaitOutcome<Result: Sendable>: Sendable {
    case finished(Result)
    /// The run never started (the job is gone, off, or its folder can't be found).
    case didNotRun
    /// The app is quitting: the run was dropped or cancelled (C3).
    case quitting
}

/// The callers waiting for jobs' runs, per job. Every waiter is answered exactly once: by its run's result, with
/// `didNotRun`, or with `quitting` when the app quits (dropped queued runs never report back on their own).
public struct RunWaiterList<Result: Sendable> {
    public typealias Answer = (RunWaitOutcome<Result>) -> Void

    private struct Waiter {
        /// Runs to let pass first: 1 when the job was already running when asked (its next run is the one asked for).
        var skips: Int
        let answer: Answer
    }

    private var waiters: [UUID: [Waiter]] = [:]
    public private(set) var isQuitting = false

    public init() {}

    public var count: Int { waiters.values.reduce(0) { $0 + $1.count } }

    /// Adds a waiter for `job`; while quitting it is answered at once.
    public mutating func add(_ job: UUID, skips: Int, answer: @escaping Answer) {
        guard !isQuitting else { return answer(.quitting) }
        waiters[job, default: []].append(Waiter(skips: skips, answer: answer))
    }

    /// Hands a finished run's result (nil: it never started) to the callers waiting for it. A waiter still skipping
    /// a run waits for the next one.
    public mutating func resume(_ job: UUID, with result: Result?) {
        guard let list = waiters.removeValue(forKey: job) else { return }
        var left: [Waiter] = []
        for var waiter in list {
            if result != nil, waiter.skips > 0 {
                waiter.skips -= 1
                left.append(waiter)
            } else {
                waiter.answer(result.map { .finished($0) } ?? (isQuitting ? .quitting : .didNotRun))
            }
        }
        if !left.isEmpty { waiters[job] = left }
    }

    /// Quitting: every waiter is answered with `quitting`, and so is every later one.
    public mutating func answerAllForQuit() {
        isQuitting = true
        let all = waiters.values.flatMap { $0 }
        waiters = [:]
        all.forEach { $0.answer(.quitting) }
    }
}
