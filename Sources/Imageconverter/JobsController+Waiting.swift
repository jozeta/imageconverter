import Foundation
import ImageconverterCore

/// One caller waiting for a job's run (the Run Job Shortcuts action).
struct RunWaiter {
    /// Runs to let pass first: 1 when the job was already running when asked (its next run is the one asked for).
    var skips: Int
    let continuation: CheckedContinuation<JobRunResult?, Never>
}

extension JobsController {
    /// Run now, then wait for that run's result; nil when the job doesn't exist, the app is quitting, or the run
    /// couldn't start (e.g. a folder that can't be found; the job's `disabledReason` says why). When the job is
    /// already running, the request becomes its follow-up run and this waits for that one.
    func runNowAndWait(_ id: UUID) async -> JobRunResult? {
        start()
        guard job(id) != nil, !isQuitting else { return nil }
        return await withCheckedContinuation { continuation in
            let skips = status(of: id).isRunning ? 1 : 0
            runWaiters[id, default: []].append(RunWaiter(skips: skips, continuation: continuation))
            runNow(id)
        }
    }

    /// Hands a finished run's result (nil: it never started) to the callers waiting for it.
    func resumeWaiters(_ id: UUID, with result: JobRunResult?) {
        guard let waiters = runWaiters.removeValue(forKey: id) else { return }
        var left: [RunWaiter] = []
        for var waiter in waiters {
            if result != nil, waiter.skips > 0 {
                waiter.skips -= 1
                left.append(waiter)
            } else {
                waiter.continuation.resume(returning: result)
            }
        }
        if !left.isEmpty { runWaiters[id] = left }
    }
}
