import Foundation
import ImageconverterCore

/// Watching, schedules and runs.
extension JobsController {
    /// Background job batches use half the cores and half the memory budget, so a manual run keeps its share.
    nonisolated static var jobConcurrency: Int { max(1, ProcessInfo.processInfo.activeProcessorCount / 2) }
    nonisolated static var jobMemoryBudget: Int { max(1, BatchRunner.defaultMemoryBudgetPixels / 2) }

    enum Origin { case user, automatic }

    func armAll() {
        for job in jobs { arm(job) }
    }

    /// Starts the job's watcher or schedule (stopping an old one first); nothing for manual, off or paused jobs.
    /// Starting to watch runs the job once, so files that arrived while nobody watched are not missed.
    func arm(_ job: Job) {
        disarm(job.id)
        guard started, job.isEnabled, !pausedAll else { return }
        switch job.trigger {
        case .manual:
            return
        case .watch:
            startWatching(job)
        case .schedule(let every):
            let last = status(of: job.id).lastChecked ?? status(of: job.id).lastSummary?.finishedAt ?? Date()
            let id = job.id
            scheduler.schedule(id, every: every, start: last) { [weak self] in
                Task { @MainActor in self?.trigger(id, .scan, origin: .automatic) }
            }
        }
    }

    func disarm(_ id: UUID) {
        scheduler.cancel(id)
        if let entry = watchers.removeValue(forKey: id) {
            entry.watcher.stop()
            entry.access.release()
        }
    }

    private func startWatching(_ job: Job) {
        guard case .ready(let ready, let changed) = resolveFolders(job) else { return }
        if changed { adopt(ready, from: job) }
        let access = FolderAccess.Grant(ready.inputs + ready.excludedFolders)
        let id = ready.id
        let watcher = FolderWatcher(folders: ready.inputs, recursive: ready.recursive,
                                    excluded: ready.excludedFolders) { [weak self] files in
            Task { @MainActor in self?.trigger(id, .files(Set(files)), origin: .automatic) }
        }
        guard watcher.start() else {
            access.release()
            var entry = status(of: id)
            entry.problem = "The folders couldn't be watched."
            status[id] = entry
            return
        }
        watchers[id] = (watcher, access)
        trigger(id, .scan, origin: .automatic)
    }

    /// The job's folders now; an unresolvable one switches the job off with a message.
    private func resolveFolders(_ job: Job) -> JobFolders.Outcome {
        let outcome = JobFolders.resolve(job)
        if case .unavailable(let reason) = outcome { disable(job.id, reason: reason + " Choose it again in the job.") }
        return outcome
    }

    /// Stores new folder URLs or bookmarks; when a folder moved, its processed files move with it in the ledger.
    private func adopt(_ ready: Job, from old: Job) {
        try? store.rebaseLedger(id: ready.id, moves: JobFolders.moves(from: old, to: ready))
        try? store.save(ready)
        replace(ready)
    }

    /// Run now (also for jobs that are off or paused: the user asked).
    func runNow(_ id: UUID) {
        trigger(id, .scan, origin: .user)
    }

    /// Starts a run, or merges the request into the job's follow-up run when it is already running.
    func trigger(_ id: UUID, _ request: JobRunRequest, origin: Origin) {
        guard let job = job(id) else { return }
        if origin == .automatic, !job.isEnabled || pausedAll { return }
        guard let start = queue.request(id, request) else { return }
        launch(job, start)
    }

    private func launch(_ job: Job, _ request: JobRunRequest) {
        guard case .ready(let ready, let changed) = resolveFolders(job) else {
            continueQueue(job.id)
            return
        }
        if changed { adopt(ready, from: job) }
        var entry = status(of: ready.id)
        entry.isRunning = true
        entry.progress = nil
        status[ready.id] = entry
        let access = ready.inputs + ready.excludedFolders
        let files = request.files
        Task { [weak self, store, presetStore] in
            let result = await Task.detached(priority: .utility) {
                await FolderAccess.withAccess(access) {
                    await JobRunner.run(ready, files: files, store: store, presetStore: presetStore,
                                        concurrency: Self.jobConcurrency, memoryBudgetPixels: Self.jobMemoryBudget,
                                        progress: { update in
                        Task { @MainActor in self?.progressed(ready.id, update) }
                    })
                }
            }.value
            self?.finished(ready, result)
        }
    }

    private func progressed(_ id: UUID, _ update: BatchProgress) {
        guard var entry = status[id], entry.isRunning,
              update.completed + update.failed >= (entry.progress.map { $0.completed + $0.failed } ?? 0) else { return }
        entry.progress = update
        status[id] = entry
    }

    private func finished(_ job: Job, _ result: JobRunResult) {
        var entry = status(of: job.id)
        entry.isRunning = false
        entry.progress = nil
        status[job.id] = entry
        record(result, job: job)
        continueQueue(job.id)
        retryWaiting(job, waiting: result.waiting)
    }

    /// Files still being copied when a scan looked are not seen again by the watcher (it only reports changes
    /// after it started): look once more when they should have settled. A file that never becomes readable
    /// stops being retried after `maxWaitRetries` checks in a row.
    private func retryWaiting(_ job: Job, waiting: Int) {
        guard waiting > 0, job.trigger == .watch else {
            waitRetries[job.id] = nil
            return
        }
        guard waitRetries[job.id, default: 0] < Self.maxWaitRetries else { return }
        waitRetries[job.id, default: 0] += 1
        let id = job.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(JobRunner.stableFor + 1))
            self?.trigger(id, .scan, origin: .automatic)
        }
    }

    /// Starts the coalesced follow-up, if any, with the job as it is now (it may have been edited meanwhile).
    private func continueQueue(_ id: UUID) {
        while let next = queue.finish(id) {
            guard let job = job(id) else { continue }
            var entry = status(of: id)
            entry.isRunning = true
            status[id] = entry
            launch(job, next)
            return
        }
    }
}
