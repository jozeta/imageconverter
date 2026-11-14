import AppKit
import Observation
import ImageconverterCore

/// What the Jobs window and the menu bar show about one job.
struct JobStatus: Equatable {
    var isRunning = false
    var progress: BatchProgress?
    /// The last run that processed files (from the run history at launch, then from this session).
    var lastSummary: RunSummary?
    /// When the job last looked at its folders, even if nothing was new.
    var lastChecked: Date?
    var lastReport: URL?
    /// The last run's problem, or why watching couldn't start.
    var problem: String?
}

/// Saved jobs and everything that runs them while the app is open: folder watchers, schedules, Run now, and a
/// queue that keeps one run per job at a time (triggers during a run become one follow-up run). Job runs are
/// background runs, independent of the main window's Run: half the cores, half the memory budget, `.utility`.
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
    /// Stops every watcher and schedule (runs in progress finish); kept between launches.
    var pausedAll: Bool {
        didSet {
            defaults.set(pausedAll, forKey: Self.pausedKey)
            armAll()
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
    @ObservationIgnored var queue = JobRunQueue()
    @ObservationIgnored var watchers: [UUID: (watcher: FolderWatcher, access: FolderAccess.Grant)] = [:]
    @ObservationIgnored let scheduler = JobScheduler()
    /// Follow-up scans for files that were still being written (see `retryWaiting`).
    @ObservationIgnored var waitRetries: [UUID: Int] = [:]
    static let maxWaitRetries = 20
    @ObservationIgnored private(set) var started = false

    static let pausedKey = "jobsPaused"
    static let menuBarKey = "keepInMenuBar"
    static let reportsKey = "jobLastReports"

    init(store: JobStore, presetStore: PresetStore, defaults: UserDefaults, history: RunHistory, errorLog: ErrorLog) {
        self.store = store
        self.presetStore = presetStore
        self.defaults = defaults
        self.history = history
        self.errorLog = errorLog
        notifier = JobNotifier(defaults: defaults)
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

    // MARK: Editing

    /// Saves a new or edited job (bookmarks made now, while the app has access to the folders just picked),
    /// then re-arms it. Throws the store's error (e.g. a duplicate name).
    func save(_ edited: Job) throws {
        var job = edited
        let previous = self.job(job.id)
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
        let firstWatch = job.isEnabled && job.trigger == .watch
            && !(previous.map { $0.isEnabled && $0.trigger == .watch } ?? false)
        if firstWatch { notifier.requestPermissionIfNeeded() }
        replace(job)
        if previous == nil { status[job.id] = JobStatus() }
        if var entry = status[job.id], job.isEnabled { entry.problem = nil; status[job.id] = entry }
        arm(job)
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
        guard !status(of: id).isRunning else { return }
        disarm(id)
        queue.dropPending(id)
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
        queue.dropPending(id)
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

    // MARK: Recording

    /// History and the error log get every run that did something or had a problem; empty checks are not stored
    /// (a watch catch-up or a 5-minute schedule would otherwise push every real run out of the history).
    func record(_ result: JobRunResult, job: Job) {
        let summary = result.report.summary
        let didWork = summary.succeeded + summary.failed + summary.skipped + summary.cancelled > 0
        if didWork || result.problem != nil { try? history.save(result.report) }
        errorLog.record(result.batch.failures.map { ($0.source.path, $0.reason) })
        if let problem = result.problem {
            errorLog.record(path: job.inputs.first?.path ?? job.name, reason: "Job \(job.name): \(problem)")
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
        guard job.trigger != .manual else { return }
        if let problem = result.problem {
            notifier.post(title: "Job \(job.name) had a problem", body: problem)
        } else if summary.succeeded + summary.failed > 0 {
            notifier.post(title: "Job \(job.name)",
                          body: RunCountsText.make(written: result.batch.written.count,
                                                   skipped: result.batch.skipped.count,
                                                   failed: result.batch.failures.count))
        }
    }

    /// Where Reveal output points: the new folder, or the first input folder for same-folder and overwrite jobs.
    static func outputFolder(of job: Job) -> URL? {
        JobRunner.reportFolder(for: job)
    }
}
