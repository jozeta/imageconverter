import Foundation

/// Steers a running batch from outside: pause and resume, files moved to the front, low-memory mode.
/// Thread-safe; the batch reads it between items, so a change takes effect when the next item would start.
public final class BatchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var lowMemory: Bool
    private var priorityRequests: [[URL]] = []

    public init(lowMemory: Bool = false) {
        self.lowMemory = lowMemory
    }

    /// No new item starts until `resume()`; items already running finish (a commit is never interrupted).
    /// Cancelling the batch's task still works while paused.
    public func pause() { locked { paused = true } }
    public func resume() { locked { paused = false } }
    public var isPaused: Bool { locked { paused } }

    /// Two workers, a quarter of the memory budget and no up-front decode caching, from the next item on.
    public func setLowMemory(_ isOn: Bool) { locked { lowMemory = isOn } }
    public var isLowMemory: Bool { locked { lowMemory } }

    /// Moves the not-yet-started items with these sources to the front of the queue, in this order. Items that
    /// already started (or finished) are left alone; the report stays in input order.
    public func prioritize(_ sources: [URL]) {
        guard !sources.isEmpty else { return }
        locked { priorityRequests.append(sources) }
    }

    func takePriorityRequests() -> [[URL]] {
        locked {
            let requests = priorityRequests
            priorityRequests = []
            return requests
        }
    }

    /// Returns when resumed or when the task is cancelled. Polls: a paused batch has nothing else to do.
    func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// What happened to one item of a batch.
public struct ItemEvent: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Planned and waiting (again after a failure that will be retried at the end).
        case queued
        case decoding
        case processing
        case encoding
        case writing
        case done
        case failed(String)
        /// A condition skipped it: nothing is written.
        case skipped
        /// The batch was cancelled before this item finished; nothing was written for it.
        case cancelled
    }

    /// The item's position in the list passed to `BatchRunner.run`.
    public let index: Int
    public let source: URL
    public let stage: Stage
    /// Set on `done`, `failed` and `skipped` when the source's size could be read.
    public let inputBytes: Int?
    /// Set on `done`.
    public let outputBytes: Int?
    /// Seconds from the start of decoding to the end; set on `done` and `failed`.
    public let duration: TimeInterval?

    public init(index: Int, source: URL, stage: Stage, inputBytes: Int? = nil, outputBytes: Int? = nil,
                duration: TimeInterval? = nil) {
        self.index = index
        self.source = source
        self.stage = stage
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.duration = duration
    }
}

/// The system's memory pressure, as the batch sees it.
public enum MemoryPressure: Sendable {
    case normal, warning, critical

    /// From the kernel's pressure level (`kern.memorystatus_vm_pressure_level`: 1, 2 or 4).
    init(kernelLevel: Int) {
        switch kernelLevel {
        case 4...: self = .critical
        case 2...: self = .warning
        default: self = .normal
        }
    }
}

/// Follows the system's memory pressure notifications for the length of a run.
final class MemoryPressureMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var level = MemoryPressure.normal
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                                 queue: .global(qos: .utility))

    init() {
        // The source only reports changes, so start from the kernel's current level.
        level = Self.currentSystemLevel() ?? .normal
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            let next: MemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            self.lock.lock()
            self.level = next
            self.lock.unlock()
        }
        source.activate()
    }

    deinit { source.cancel() }

    /// `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical), the level the dispatch
    /// source's notifications follow; nil when it can't be read.
    static func currentSystemLevel() -> MemoryPressure? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return nil }
        return MemoryPressure(kernelLevel: Int(value))
    }

    var current: MemoryPressure {
        lock.lock()
        defer { lock.unlock() }
        return level
    }
}

/// What the worker limits adapt to.
struct BatchConditions: Equatable {
    var thermal: ProcessInfo.ThermalState = .nominal
    var pressure: MemoryPressure = .normal
    var lowMemory = false
    /// The end-of-batch retry pass.
    var retrying = false
}

/// How many items may run at once and their combined weight (pixels), re-evaluated between items.
struct BatchLimits: Equatable {
    let maxItems: Int
    let maxWeight: Int

    /// `concurrency` and `budget` are the run's own limits. A serious thermal state halves the workers and a
    /// critical one leaves one; a memory warning halves the budget and critical pressure leaves one worker;
    /// low-memory mode is at most 2 workers and a quarter of the budget; the end-of-batch retry runs alone.
    static func effective(concurrency: Int, budget: Int, conditions: BatchConditions) -> BatchLimits {
        var items = max(1, concurrency)
        var weight = max(1, budget)
        switch conditions.thermal {
        case .serious: items = max(1, items / 2)
        case .critical: items = 1
        default: break
        }
        switch conditions.pressure {
        case .warning: weight = max(1, weight / 2)
        case .critical: items = 1
        case .normal: break
        }
        if conditions.lowMemory {
            items = min(items, 2)
            weight = max(1, weight / 4)
        }
        if conditions.retrying { items = 1 }
        return BatchLimits(maxItems: items, maxWeight: weight)
    }
}

/// Seams for tests: the system state the batch adapts to, and a hook into each encode.
struct BatchHooks: Sendable {
    var thermalState: @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    /// Nil: the run follows the system's memory pressure notifications.
    var memoryPressure: (@Sendable () -> MemoryPressure)?
    /// Called on the worker just before an item is encoded, with its source and attempt (1, or 2 on the retry);
    /// throwing fails that attempt.
    var beforeEncode: (@Sendable (URL, Int) throws -> Void)?
}
