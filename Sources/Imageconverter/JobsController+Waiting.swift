import Foundation
import ImageconverterCore

extension JobsController {
    /// Run now, then wait for that run's result (the Run Job Shortcuts action). `didNotRun` when the job doesn't
    /// exist or the run couldn't start (e.g. a folder that can't be found; the job's `disabledReason` says why);
    /// `quitting` when the app is quitting, also for a run that was waiting and is dropped by the quit
    /// (`stopForQuit` answers every waiter). When the job is already running, the request becomes its follow-up
    /// run and this waits for that one.
    func runNowAndWait(_ id: UUID) async -> RunWaitOutcome<JobRunResult> {
        start()
        guard !isQuitting else { return .quitting }
        guard job(id) != nil else { return .didNotRun }
        return await withCheckedContinuation { continuation in
            let skips = status(of: id).isRunning ? 1 : 0
            runWaiters.add(id, skips: skips) { continuation.resume(returning: $0) }
            runNow(id)
        }
    }

    /// Hands a finished run's result (nil: it never started) to the callers waiting for it.
    func resumeWaiters(_ id: UUID, with result: JobRunResult?) {
        runWaiters.resume(id, with: result)
    }
}
