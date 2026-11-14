import Foundation

/// What resuming an interrupted batch would do: the images still to do that are still there, the ones that are
/// gone, and the batch's own pipeline and output mode (used for that run only; the app's settings stay as they are).
public struct ResumePlan: Equatable, Sendable {
    public enum Problem: Equatable, Sendable {
        /// Every remaining image is gone (or none remained).
        case nothingLeft
        /// The batch wrote into a new folder that no longer exists.
        case outputFolderMissing(URL)
    }

    /// The remaining images that still exist, in their original order.
    public let toRun: [InputItem]
    /// The part of `toRun` that isn't in the list already.
    public let toAdd: [InputItem]
    public let missing: [URL]
    public let pipeline: Pipeline
    public let mode: OutputMode
    public let problem: Problem?

    /// Overwriting originals is never resumed without the user confirming it again.
    public var needsOverwriteConfirmation: Bool { mode == .overwrite }

    /// `fileExists` and `directoryExists` take paths; injected so the plan is testable without files.
    public static func make(journal: RunJournal, existing: [InputItem], fileExists: (String) -> Bool,
                            directoryExists: (String) -> Bool) -> ResumePlan {
        let remaining = journal.remainingItems
        let toRun = remaining.filter { fileExists($0.source.path) }
        let present = Set(toRun)
        let missing = remaining.filter { !present.contains($0) }.map(\.source)
        let known = Set(existing)
        var problem: Problem?
        if toRun.isEmpty {
            problem = .nothingLeft
        } else if case .newFolder(let folder) = journal.outputMode, !directoryExists(folder.path) {
            problem = .outputFolderMissing(folder)
        }
        return ResumePlan(toRun: toRun, toAdd: toRun.filter { !known.contains($0) }, missing: missing,
                          pipeline: journal.pipeline, mode: journal.outputMode, problem: problem)
    }

    /// "the folder Out", "the same folder as each original (suffix _new)", "overwrite the original files".
    public static func describe(_ mode: OutputMode) -> String {
        switch mode {
        case .newFolder(let folder): return "the folder \(folder.lastPathComponent)"
        case .sameFolder(let suffix): return "the same folder as each original (suffix \(suffix))"
        case .overwrite: return "overwrite the original files"
        }
    }
}

/// A clock that stops while paused, so a paused batch's rate, ETA and elapsed time leave the pause out.
/// Thread-safe (`RunMetrics` takes a `@Sendable` clock).
public final class PausableClock: @unchecked Sendable {
    private let lock = NSLock()
    private let source: @Sendable () -> TimeInterval
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: TimeInterval?

    public init(source: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source
    }

    public func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return (pausedAt ?? source()) - pausedTotal
    }

    public func pause() {
        lock.lock()
        defer { lock.unlock() }
        if pausedAt == nil { pausedAt = source() }
    }

    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard let start = pausedAt else { return }
        pausedTotal += source() - start
        pausedAt = nil
    }
}
