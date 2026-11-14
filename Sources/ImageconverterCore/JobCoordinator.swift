import Foundation

/// Who asked for a job run: the user (Run now, a confirmed link) or a watcher, schedule or catch-up.
public enum JobRunOrigin: Equatable, Sendable { case user, automatic }

/// The app's job runs as a pure state machine: one run per job at a time (triggers during a run are merged into
/// one follow-up), at most `maxActive` job batches at once across all jobs (the rest wait in request order), and
/// automatic requests only while their job may run (switched on, not paused). Folder changes that must not happen
/// during a run (a ledger rebase) wait for it to end (`rearmWhenIdle`). The caller performs the returned actions.
public struct JobCoordinator: Sendable {
    public enum Action: Equatable, Sendable {
        /// Start a run now.
        case start(UUID, JobRunRequest, JobRunOrigin)
        /// The job's run ended and its watcher must be set up again (it adopts moved folders now). Call
        /// `startReady` afterwards.
        case rearm(UUID)
    }

    public let maxActive: Int
    public private(set) var active: Set<UUID> = []
    private var pending: [UUID: (request: JobRunRequest, origin: JobRunOrigin)] = [:]
    /// Waiting jobs, oldest request first.
    private var order: [UUID] = []
    private var rearmAfterRun: Set<UUID> = []

    public init(maxActive: Int = 1) {
        self.maxActive = max(1, maxActive)
    }

    public func isActive(_ id: UUID) -> Bool { active.contains(id) }
    public func isQueued(_ id: UUID) -> Bool { pending[id] != nil }
    public func pendingOrigin(_ id: UUID) -> JobRunOrigin? { pending[id]?.origin }

    /// `allowed(id)`: whether an automatic run of that job may start. A user request always may.
    public mutating func request(_ id: UUID, _ request: JobRunRequest, origin: JobRunOrigin,
                                 allowed: (UUID) -> Bool) -> [Action] {
        if origin == .automatic, !allowed(id) { return [] }
        if let existing = pending[id] {
            pending[id] = (existing.request.merged(with: request), existing.origin == .user ? .user : origin)
        } else {
            pending[id] = (request, origin)
            order.append(id)
        }
        return startReady(allowed: allowed)
    }

    /// A run ended (or couldn't start). Returns what to do next: a re-arm, or the runs that may start now.
    public mutating func finished(_ id: UUID, allowed: (UUID) -> Bool) -> [Action] {
        active.remove(id)
        if rearmAfterRun.remove(id) != nil { return [.rearm(id)] }
        return startReady(allowed: allowed)
    }

    /// Starts waiting runs while the budget allows, oldest first; automatic requests that may no longer run are
    /// dropped on the way.
    public mutating func startReady(allowed: (UUID) -> Bool) -> [Action] {
        prune(allowed: allowed)
        var actions: [Action] = []
        for id in order where active.count < maxActive && !active.contains(id) {
            guard let next = pending.removeValue(forKey: id) else { continue }
            active.insert(id)
            actions.append(.start(id, next.request, next.origin))
        }
        order.removeAll { pending[$0] == nil }
        return actions
    }

    /// Drops the waiting automatic requests of jobs that may no longer run (Pause all, Switch off).
    public mutating func prune(allowed: (UUID) -> Bool) {
        for id in order where pending[id]?.origin == .automatic && !allowed(id) { pending[id] = nil }
        order.removeAll { pending[$0] == nil }
    }

    /// Forgets everything waiting for the job (deleted).
    public mutating func drop(_ id: UUID) {
        pending[id] = nil
        order.removeAll { $0 == id }
        rearmAfterRun.remove(id)
    }

    /// The job's folders changed while it runs: set its watcher up again once the run ends.
    public mutating func rearmWhenIdle(_ id: UUID) {
        rearmAfterRun.insert(id)
    }
}

/// Notifications for background job runs, at most one per job per `interval`: runs in between are added up and
/// posted together once the interval has passed.
public struct JobNoticeCoalescer: Sendable {
    public static let interval: TimeInterval = 60

    /// One run's counts.
    public struct Counts: Equatable, Sendable {
        public var written: Int
        public var skipped: Int
        public var failed: Int
        public var problem: String?

        public init(written: Int, skipped: Int = 0, failed: Int = 0, problem: String? = nil) {
            self.written = written
            self.skipped = skipped
            self.failed = failed
            self.problem = problem
        }
    }

    public struct Notice: Equatable, Sendable {
        public var title: String
        public var body: String
    }

    private struct Totals {
        var name: String
        var written = 0
        var skipped = 0
        var failed = 0
        var runs = 0
        var problem: String?
    }

    private var lastPosted: [UUID: Date] = [:]
    private var waiting: [UUID: Totals] = [:]

    public init() {}

    /// Adds a run's counts; returns the notice to post now, or nil (nothing worth saying, or wait until
    /// `flushDate(for:)` and call `flush`).
    public mutating func add(_ id: UUID, name: String, counts: Counts, now: Date) -> Notice? {
        guard counts.written + counts.failed > 0 || counts.problem != nil else { return nil }
        var totals = waiting[id] ?? Totals(name: name)
        totals.name = name
        totals.written += counts.written
        totals.skipped += counts.skipped
        totals.failed += counts.failed
        totals.runs += 1
        if let problem = counts.problem { totals.problem = problem }
        waiting[id] = totals
        guard let last = lastPosted[id], now.timeIntervalSince(last) < Self.interval else { return flush(id, now: now) }
        return nil
    }

    /// When the waiting notice of `id` may be posted; nil when nothing waits.
    public func flushDate(for id: UUID) -> Date? {
        guard waiting[id] != nil else { return nil }
        return lastPosted[id].map { $0.addingTimeInterval(Self.interval) } ?? .distantPast
    }

    /// The waiting notice, if any (the caller decides it's time).
    public mutating func flush(_ id: UUID, now: Date) -> Notice? {
        guard let totals = waiting.removeValue(forKey: id) else { return nil }
        lastPosted[id] = now
        let counts = RunCountsText.make(written: totals.written, skipped: totals.skipped, failed: totals.failed)
            + (totals.runs > 1 ? " in \(totals.runs) runs" : "")
        if let problem = totals.problem {
            let suffix = totals.written + totals.failed > 0 ? " " + counts : ""
            return Notice(title: "Job \(totals.name) had a problem", body: problem + suffix)
        }
        return Notice(title: "Job \(totals.name)", body: counts)
    }
}
