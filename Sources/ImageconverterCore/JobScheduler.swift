import Foundation

/// Runs scheduled jobs: one repeating wall-clock timer per job (so time asleep counts), on `queue`.
public final class JobScheduler: @unchecked Sendable {
    private let queue: DispatchQueue
    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var timers: [UUID: DispatchSourceTimer] = [:]

    public convenience init(queue: DispatchQueue = DispatchQueue(label: "imageconverter.job-scheduler")) {
        self.init(queue: queue, minimumInterval: JobSchedule.minimumInterval)
    }

    /// Tests pass a shorter minimum; the app always uses `JobSchedule.minimumInterval`.
    init(queue: DispatchQueue, minimumInterval: TimeInterval) {
        self.queue = queue
        self.minimumInterval = minimumInterval
    }

    deinit { cancelAll() }

    public var scheduledIDs: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(timers.keys)
    }

    /// Calls `action` every `interval` seconds (at least the minimum), first at `nextRun(after: start)`.
    /// Replaces an earlier schedule for the same id.
    public func schedule(_ id: UUID, every interval: TimeInterval, start: Date = Date(),
                         action: @escaping @Sendable () -> Void) {
        let every = interval.isFinite ? max(interval, minimumInterval) : minimumInterval
        let delay = max(0, start.addingTimeInterval(every).timeIntervalSinceNow)
        let source = DispatchSource.makeTimerSource(queue: queue)
        // 5 % slack lets the system batch wake-ups, but never more than a minute late.
        let leeway = min(every * 0.05, 60)
        source.schedule(wallDeadline: .now() + delay, repeating: every, leeway: .milliseconds(Int(leeway * 1000)))
        source.setEventHandler(handler: action)
        lock.lock()
        let old = timers.updateValue(source, forKey: id)
        lock.unlock()
        old?.cancel()
        source.resume()
    }

    public func cancel(_ id: UUID) {
        lock.lock()
        let old = timers.removeValue(forKey: id)
        lock.unlock()
        old?.cancel()
    }

    public func cancelAll() {
        lock.lock()
        let all = timers.values
        timers = [:]
        lock.unlock()
        all.forEach { $0.cancel() }
    }
}
