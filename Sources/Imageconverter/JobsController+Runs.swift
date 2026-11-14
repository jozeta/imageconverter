import Foundation
import ImageconverterCore

/// Watching, schedules and runs.
extension JobsController {
    /// Job batches run one at a time with half the cores and half the memory budget, so a manual run keeps its share.
    nonisolated static var jobConcurrency: Int { max(1, ProcessInfo.processInfo.activeProcessorCount / 2) }
    nonisolated static var jobMemoryBudget: Int { max(1, BatchRunner.defaultMemoryBudgetPixels / 2) }

    func armAll() {
        for job in jobs { arm(job) }
    }

    /// Starts the job's watcher or schedule (stopping an old one first); nothing for manual, off or paused jobs.
    /// Starting to watch runs the job once, so files that arrived while nobody watched are not missed.
    func arm(_ job: Job) {
        disarm(job.id)
        guard started, mayRun(job.id) else { return }
        switch job.trigger {
        case .manual:
            return
        case .watch:
            startWatching(job, catchUp: true)
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

    /// Watches the folders, holding access to the URLs their bookmarks resolved to for as long as it watches.
    /// A folder that moved while the job runs is adopted (ledger rebased) only once the run has ended.
    private func startWatching(_ job: Job, catchUp: Bool) {
        guard case .ready(let ready, let changed, let access) = resolveFolders(job) else { return }
        if changed {
            if coordinator.isActive(job.id) {
                coordinator.rearmWhenIdle(job.id)
                return
            }
            guard adopt(ready, from: job) else { return }
        }
        let grant = FolderAccess.Grant(access)
        let id = ready.id
        let watcher = FolderWatcher(folders: ready.inputs, recursive: ready.recursive,
                                    excluded: ready.excludedFolders) { [weak self] files in
            Task { @MainActor in self?.trigger(id, .files(Set(files)), origin: .automatic) }
        }
        guard watcher.start() else {
            grant.release()
            var entry = status(of: id)
            entry.problem = "The folders couldn't be watched."
            status[id] = entry
            return
        }
        watchers[id] = (watcher, grant)
        if catchUp { trigger(id, .scan, origin: .automatic) }
    }

    /// The job's folders now; an unresolvable one switches the job off with a message.
    private func resolveFolders(_ job: Job) -> JobFolders.Outcome {
        let outcome = JobFolders.resolve(job)
        if case .unavailable(let reason) = outcome { disable(job.id, reason: reason + " Choose it again in the job.") }
        return outcome
    }

    /// Stores new folder URLs or bookmarks; when a folder moved, its processed files move with it in the ledger
    /// first. Never called while the job's batch runs. False (and the job left as it was) when the rebase failed.
    private func adopt(_ ready: Job, from old: Job) -> Bool {
        do {
            try store.rebaseLedger(id: ready.id, moves: JobFolders.moves(from: old, to: ready))
        } catch {
            var entry = status(of: ready.id)
            entry.problem = "The folder moved, but the list of processed files couldn't be moved with it: "
                + error.localizedDescription
            status[ready.id] = entry
            return false
        }
        try? store.save(ready)
        replace(ready)
        return true
    }

    /// Run now (also for jobs that are off or paused: the user asked).
    func runNow(_ id: UUID) {
        trigger(id, .scan, origin: .user)
    }

    /// Starts a run, or queues it (merged with the job's waiting run) until the job and the shared slot are free.
    func trigger(_ id: UUID, _ request: JobRunRequest, origin: JobRunOrigin) {
        guard job(id) != nil, !isQuitting else { return }
        perform(coordinator.request(id, request, origin: origin, allowed: mayRun))
    }

    func perform(_ actions: [JobCoordinator.Action]) {
        for action in actions {
            switch action {
            case .start(let id, let request, let origin):
                launch(id, request, origin: origin)
            case .rearm(let id):
                if let job = job(id) { arm(job) }
                perform(coordinator.startReady(allowed: mayRun))
            }
        }
        syncRunState()
    }

    /// Every path out of a run (finished, or failed to start) ends here, so the job never stays "Running".
    private func endRun(_ id: UUID) {
        runTasks[id] = nil
        userRuns.remove(id)
        perform(coordinator.finished(id, allowed: mayRun))
    }

    private func launch(_ id: UUID, _ request: JobRunRequest, origin: JobRunOrigin) {
        guard let job = job(id) else { return endRun(id) }
        guard case .ready(let ready, let changed, let access) = resolveFolders(job) else {
            if origin == .user, let reason = self.job(id)?.disabledReason {
                messenger?("Job \(job.name) didn't run. \(reason)", true)
            }
            return endRun(id)
        }
        if changed {
            // Safe here: this job's batch hasn't started yet.
            guard adopt(ready, from: job) else { return endRun(id) }
            // The watcher follows the moved folder too.
            if watchers[id] != nil {
                disarm(id)
                startWatching(ready, catchUp: false)
            }
        }
        if origin == .user { userRuns.insert(id) }
        var entry = status(of: id)
        entry.progress = nil
        status[id] = entry
        let files = request.files
        // The controller lives as long as the app (`shared`): a strong capture is fine.
        runTasks[id] = Task.detached(priority: .utility) { [self, store, presetStore] in
            let result = await FolderAccess.withAccess(access) {
                await JobRunner.run(ready, files: files, store: store, presetStore: presetStore,
                                    concurrency: Self.jobConcurrency, memoryBudgetPixels: Self.jobMemoryBudget,
                                    progress: { update in
                    Task { @MainActor in self.progressed(id, update) }
                })
            }
            await self.finished(ready, result)
        }
    }

    private func progressed(_ id: UUID, _ update: BatchProgress) {
        guard var entry = status[id], entry.isRunning,
              update.completed + update.failed >= (entry.progress.map { $0.completed + $0.failed } ?? 0) else { return }
        entry.progress = update
        status[id] = entry
    }

    private func finished(_ job: Job, _ result: JobRunResult) {
        record(result, job: job, byUser: userRuns.contains(job.id))
        endRun(job.id)
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
}
