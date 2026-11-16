import AppKit
import Observation
import ImageconverterCore

/// What the Jobs window and the menu bar show about one job.
struct JobStatus: Equatable {
    /// Its batch is running (mirrors `JobCoordinator.isActive`).
    var isRunning = false
    /// A run waits: for the job's own run to end, or for another job's (one job batch at a time).
    var isQueued = false
    var progress: BatchProgress?
    /// The last run that processed files (from the run history at launch, then from this session).
    var lastSummary: RunSummary?
    /// When the job last looked at its folders, even if nothing was new.
    var lastChecked: Date?
    var lastReport: URL?
    /// The last run's problem, or why watching couldn't start.
    var problem: String?
}

/// Saved jobs and everything that runs them while the app is open: folder watchers, schedules, Run now, and the
/// `JobCoordinator` (one run per job, triggers during a run merged into one follow-up, one job batch at a time
/// across all jobs). Job runs are background runs, independent of the main window's Run, at `.utility` with half
/// the cores and half the memory budget in total.
@MainActor @Observable
final class JobsController {
    static let shared = JobsController(
        store: JobStore(directory: AppDefaults.jobsDirectory),
        presetStore: PresetStore(directory: AppDefaults.presetsDirectory),
        defaults: AppDefaults.store,
        history: .shared(directory: AppDefaults.historyDirectory),
        errorLog: .shared(directory: AppDefaults.logsDirectory))

    private(set) var jobs: [Job] = []
    /// Set by the controller only (the run extension lives in another file).
    var status: [UUID: JobStatus] = [:]
    /// Job files that couldn't be loaded, and why.
    private(set) var skipped: [(file: String, reason: String)] = []
    /// Stops every watcher and schedule and drops waiting automatic runs (a run in progress finishes); kept
    /// between launches.
    var pausedAll: Bool {
        didSet {
            defaults.set(pausedAll, forKey: Self.pausedKey)
            armAll()
            coordinator.prune(allowed: mayRun)
            syncRunState()
        }
    }
    /// "Keep running in the menu bar when the window is closed".
    var keepInMenuBar: Bool {
        didSet { defaults.set(keepInMenuBar, forKey: Self.menuBarKey) }
    }

    let store: JobStore
    @ObservationIgnored let presetStore: PresetStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let history: RunHistory
    @ObservationIgnored private let errorLog: ErrorLog
    @ObservationIgnored let notifier: JobNotifier
    @ObservationIgnored var coordinator = JobCoordinator(maxActive: 1)
    @ObservationIgnored var runTasks: [UUID: Task<Void, Never>] = [:]
    /// Jobs whose current run the user started (Run now, a link): they get a toast instead of a notification.
    @ObservationIgnored var userRuns: Set<UUID> = []
    @ObservationIgnored var watchers: [UUID: (watcher: FolderWatcher, access: FolderAccess.Grant)] = [:]
    @ObservationIgnored let scheduler = JobScheduler()
    /// Follow-up scans for files that were still being written (see `retryWaiting`).
    @ObservationIgnored var waitRetries: [UUID: Int] = [:]
    /// Shortcuts actions waiting for a job's run to end (see `runNowAndWait`).
    @ObservationIgnored var runWaiters: [UUID: [RunWaiter]] = [:]
    static let maxWaitRetries = 20
    @ObservationIgnored private var notices = JobNoticeCoalescer()
    @ObservationIgnored private var noticeFlushes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var started = false
    @ObservationIgnored private var pendingWrites = 0
    /// Set by the quit coordinator: nothing new starts.
    @ObservationIgnored private(set) var isQuitting = false
    /// Shows a message in the main window (toast); set once the window is up.
    @ObservationIgnored var messenger: ((_ text: String, _ isProblem: Bool) -> Void)?

    static let pausedKey = "jobsPaused"
    static let menuBarKey = "keepInMenuBar"
    static let reportsKey = "jobLastReports"

    init(store: JobStore, presetStore: PresetStore, defaults: UserDefaults, history: RunHistory, errorLog: ErrorLog) {
        self.store = store
        self.presetStore = presetStore
        self.defaults = defaults
        self.history = history
        self.errorLog = errorLog
        notifier = JobNotifier.shared
        pausedAll = defaults.bool(forKey: Self.pausedKey)
        keepInMenuBar = defaults.bool(forKey: Self.menuBarKey)
    }

    /// Loads the jobs and starts watching and schedules; once per launch.
    func start() {
        guard !started else { return }
        started = true
        reload()
        let summaries = history.summaries()
        let reports = defaults.dictionary(forKey: Self.reportsKey) as? [String: String] ?? [:]
        for job in jobs {
            var entry = status[job.id] ?? JobStatus()
            entry.lastSummary = summaries.first { $0.jobName == job.name }
            entry.lastReport = reports[job.id.uuidString].map { URL(fileURLWithPath: $0) }
            status[job.id] = entry
        }
        // Jobs made elsewhere (the command line, an older version) never went through the editor's question.
        if jobs.contains(where: Self.postsNotifications) { notifier.requestPermissionIfNeeded() }
        armAll()
    }

    func reload() {
        let result = store.load()
        jobs = result.jobs
        skipped = result.skipped
    }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    func status(of id: UUID) -> JobStatus { status[id] ?? JobStatus() }

    var runningCount: Int { status.values.filter(\.isRunning).count }

    /// Whether an automatic run of the job may start: it exists, is switched on, and nothing is paused.
    func mayRun(_ id: UUID) -> Bool {
        !pausedAll && !isQuitting && (job(id)?.isEnabled ?? false)
    }

    /// Watched and scheduled jobs that are switched on post notifications.
    static func postsNotifications(_ job: Job) -> Bool { job.isEnabled && job.trigger != .manual }

    // MARK: Editing

    /// Saves a new or edited job (bookmarks made now, while the app has access to the folders just picked), then
    /// re-arms it. With `base` (the job as the editor opened it), only the fields the user changed are applied to
    /// the job as it is now. Throws the store's error (e.g. a duplicate name).
    func save(_ edited: Job, base: Job? = nil) throws {
        let previous = self.job(edited.id)
        var job = edited
        if let base, let previous { job = Job.merge(base: base, edited: edited, current: previous) }
        job.inputBookmarks = bookmarks(for: job.inputs, previous: previous)
        if case .newFolder(let root) = job.output {
            let reuse = previous.flatMap { old -> Data? in
                guard case .newFolder(let oldRoot) = old.output, oldRoot == root else { return nil }
                return old.outputBookmark
            }
            job.outputBookmark = reuse ?? FolderAccess.bookmark(for: root)
        } else {
            job.outputBookmark = nil
        }
        if job.isEnabled { job.disabledReason = nil }
        try store.save(job)
        if Self.postsNotifications(job) { notifier.requestPermissionIfNeeded() }
        replace(job)
        if previous == nil { status[job.id] = JobStatus() }
        if var entry = status[job.id], job.isEnabled { entry.problem = nil; status[job.id] = entry }
        arm(job)
        coordinator.prune(allowed: mayRun)
        syncRunState()
    }

    /// Bookmarks aligned with `inputs`: kept for folders that didn't change, made for new ones.
    private func bookmarks(for inputs: [URL], previous: Job?) -> [Data]? {
        var known: [URL: Data] = [:]
        if let previous, let old = previous.inputBookmarks, old.count == previous.inputs.count {
            for (url, data) in zip(previous.inputs, old) { known[url] = data }
        }
        let made = inputs.compactMap { known[$0] ?? FolderAccess.bookmark(for: $0) }
        return made.count == inputs.count ? made : nil
    }

    func delete(_ id: UUID) throws {
        guard !coordinator.isActive(id) else { return }
        disarm(id)
        coordinator.drop(id)
        resumeWaiters(id, with: nil)
        try store.delete(id: id)
        jobs.removeAll { $0.id == id }
        status[id] = nil
        rememberReport(nil, for: id)
    }

    /// Forgets which files were processed, so the next run processes everything again.
    func resetProcessed(_ id: UUID) throws {
        try store.resetLedger(id: id)
    }

    func setEnabled(_ id: UUID, _ isOn: Bool) {
        guard var job = job(id), job.isEnabled != isOn else { return }
        job.isEnabled = isOn
        try? save(job)
    }

    /// Switches a job off with a reason the user sees (a folder can't be found).
    func disable(_ id: UUID, reason: String) {
        guard var job = job(id) else { return }
        job.isEnabled = false
        job.disabledReason = reason
        try? store.save(job)
        replace(job)
        disarm(id)
        coordinator.prune(allowed: mayRun)
        var entry = status(of: id)
        entry.problem = reason
        status[id] = entry
        if job.trigger != .manual { notifier.post(title: "Job \(job.name) was switched off", body: reason) }
    }

    func replace(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        jobs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func rememberReport(_ url: URL?, for id: UUID) {
        var reports = defaults.dictionary(forKey: Self.reportsKey) as? [String: String] ?? [:]
        reports[id.uuidString] = url?.path
        defaults.set(reports, forKey: Self.reportsKey)
    }

    /// Mirrors the coordinator into the statuses the views show.
    func syncRunState() {
        for job in jobs {
            let running = coordinator.isActive(job.id)
            let queued = coordinator.isQueued(job.id)
            guard status(of: job.id).isRunning != running || status(of: job.id).isQueued != queued else { continue }
            var entry = status(of: job.id)
            entry.isRunning = running
            entry.isQueued = queued
            if !running { entry.progress = nil }
            status[job.id] = entry
        }
    }

    // MARK: Quitting

    var hasActiveRuns: Bool { !coordinator.active.isEmpty }
    /// History and error-log writes still in flight (quitting waits for them).
    var hasPendingWrites: Bool { pendingWrites > 0 }

    /// Quit was confirmed: nothing new starts, waiting runs are dropped, running ones are cancelled (they record
    /// what they finished in the ledger and history before they end).
    func stopForQuit() {
        isQuitting = true
        jobs.forEach { disarm($0.id); coordinator.drop($0.id) }
        runTasks.values.forEach { $0.cancel() }
    }

    // MARK: Recording

    /// History and the error log get every run that did something or had a problem; empty checks are not stored
    /// (a watch catch-up or a 5-minute schedule would otherwise push every real run out of the history). The files
    /// are written off the main thread.
    func record(_ result: JobRunResult, job: Job, byUser: Bool) {
        let summary = result.report.summary
        let didWork = summary.succeeded + summary.failed + summary.skipped + summary.cancelled > 0
        let failures = result.batch.failures.map { (path: $0.source.path, reason: $0.reason) }
            + result.batch.extraFailures.map { (path: $0.source.path, reason: $0.message) }
        let problem = result.problem.map { (path: job.inputs.first?.path ?? job.name, reason: "Job \(job.name): \($0)") }
        pendingWrites += 1
        // The controller lives as long as the app (`shared`): a strong capture is fine.
        Task.detached(priority: .utility) { [self, history, errorLog, report = result.report] in
            if didWork || problem != nil { try? history.save(report) }
            errorLog.record(failures + (problem.map { [$0] } ?? []))
            await MainActor.run {
                self.pendingWrites -= 1
                // After the save, so the History window reads the new run.
                NotificationCenter.default.post(name: .runHistoryChanged, object: nil)
            }
        }
        var entry = status(of: job.id)
        entry.lastChecked = summary.finishedAt
        if didWork { entry.lastSummary = summary }
        if let report = result.reportFile {
            entry.lastReport = report
            rememberReport(report, for: job.id)
        }
        entry.problem = result.problem
        status[job.id] = entry
        let batch = result.batch
        if byUser {
            if let problem = result.problem {
                messenger?("Job \(job.name): \(problem)", true)
            } else {
                let extras = batch.extraFailures.isEmpty ? "" : " · " + RunCountsText.extraFailures(batch.extraFailures.count)
                messenger?("Job \(job.name): " + RunCountsText.make(written: batch.convertedCount, skipped: batch.skipped.count,
                                                                    failed: batch.failures.count) + extras,
                           !batch.failures.isEmpty || !batch.extraFailures.isEmpty)
            }
        } else if job.trigger != .manual {
            notify(job, written: batch.convertedCount, skipped: batch.skipped.count, failed: batch.failures.count,
                   problem: result.problem)
        }
    }

    /// At most one notification per job per minute; runs in between are summed up in the next one.
    private func notify(_ job: Job, written: Int, skipped: Int, failed: Int, problem: String?) {
        let counts = JobNoticeCoalescer.Counts(written: written, skipped: skipped, failed: failed, problem: problem)
        if let notice = notices.add(job.id, name: job.name, counts: counts, now: Date()) {
            notifier.post(title: notice.title, body: notice.body)
            return
        }
        guard noticeFlushes[job.id] == nil, let date = notices.flushDate(for: job.id) else { return }
        let id = job.id
        noticeFlushes[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard let self else { return }
            self.noticeFlushes[id] = nil
            if let notice = self.notices.flush(id, now: Date()) { self.notifier.post(title: notice.title, body: notice.body) }
        }
    }

    /// Where Reveal output points: the new folder, or the first input folder for same-folder and overwrite jobs.
    static func outputFolder(of job: Job) -> URL? {
        JobRunner.reportFolder(for: job)
    }
}
