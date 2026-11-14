import Foundation
import ImageconverterCore

extension AppModel {
    /// Runs a saved job (an `imageconverter://jobs/run` link the user confirmed). Returns false when busy.
    @discardableResult
    func startJobRun(_ job: Job, store: JobStore) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        resetPreview()
        cancelEstimate()
        runReport = nil
        progress = BatchProgress(completed: 0, failed: 0, total: 0)
        task = Task { [weak self, presetStore] in
            let result = await JobRunner.run(job, store: store, presetStore: presetStore, progress: { update in
                Task { @MainActor in
                    guard let self, self.isRunning, update.completed >= (self.progress?.completed ?? 0) else { return }
                    self.progress = update
                }
            })
            self?.finishJob(result, name: job.name)
        }
        return true
    }

    private func finishJob(_ result: JobRunResult, name: String) {
        isRunning = false
        task = nil
        progress = nil
        runReport = result.report
        schedulePreview(mode: previewMode)
        scheduleEstimate()
        if let problem = result.problem {
            toasts.show("Job \(name) didn't run", type: .bad, description: problem)
            return
        }
        let batch = result.batch
        toasts.show("Job \(name): " + RunCountsText.make(written: batch.written.count, skipped: batch.skipped.count,
                                                          failed: batch.failures.count),
                    type: batch.failures.isEmpty ? .ok : .bad)
    }
}
