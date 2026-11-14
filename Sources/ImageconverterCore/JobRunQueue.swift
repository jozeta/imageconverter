import Foundation

/// What a trigger asks a job to look at.
public enum JobRunRequest: Equatable, Sendable {
    /// Everything in its folders (manual, schedule, catch-up).
    case scan
    /// Files a watcher found ready.
    case files(Set<URL>)

    /// A scan covers any files; files add up.
    public func merged(with other: JobRunRequest) -> JobRunRequest {
        switch (self, other) {
        case (.files(let lhs), .files(let rhs)): return .files(lhs.union(rhs))
        default: return .scan
        }
    }

    /// The `files:` argument of `JobRunner.run`.
    public var files: [URL]? {
        guard case .files(let set) = self else { return nil }
        return set.sorted { $0.path < $1.path }
    }
}

/// One run at a time per job: a trigger that arrives while the job runs is kept and merged with any others into
/// one follow-up run, which starts when the current one finishes. Pure bookkeeping; the caller starts the runs.
public struct JobRunQueue: Sendable {
    private var running: Set<UUID> = []
    private var pending: [UUID: JobRunRequest] = [:]

    public init() {}

    public var runningIDs: Set<UUID> { running }

    public func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    public func hasPending(_ id: UUID) -> Bool { pending[id] != nil }

    /// The request to start now, or nil when the job is already running (the request then waits, merged).
    public mutating func request(_ id: UUID, _ request: JobRunRequest) -> JobRunRequest? {
        guard running.contains(id) else {
            running.insert(id)
            return request
        }
        pending[id] = pending[id].map { $0.merged(with: request) } ?? request
        return nil
    }

    /// The run of `id` ended: the follow-up to start now (the job stays running), or nil (it is idle).
    public mutating func finish(_ id: UUID) -> JobRunRequest? {
        if let next = pending.removeValue(forKey: id) { return next }
        running.remove(id)
        return nil
    }

    /// Drops a waiting follow-up (the job was paused, switched off or deleted); a run in progress finishes.
    public mutating func dropPending(_ id: UUID) {
        pending[id] = nil
    }
}
