import Foundation

/// What resuming an interrupted batch would do: the images still to do that are still there, the ones that are
/// gone, and the batch's own pipeline and output mode (used for that run only; the app's settings stay as they are).
public struct ResumePlan: Equatable, Sendable {
    public enum Problem: Equatable, Sendable {
        /// No remaining image can be run (all gone, couldn't be opened, or already replaced; or none remained).
        case nothingLeft
        /// The batch wrote into a new folder that no longer exists.
        case outputFolderMissing(URL)
    }

    /// The remaining images that can be read, in their original order.
    public let toRun: [InputItem]
    /// The part of `toRun` that isn't in the list already.
    public let toAdd: [InputItem]
    /// Remaining images that can't be read and whose folder the app may read: they are gone (or unreadable).
    public let missing: [URL]
    /// Remaining images that can't be read in a folder the user didn't allow when asked (sandbox): reported as
    /// "couldn't open", never as missing.
    public let unopened: [URL]
    /// Overwrite mode: remaining sources that changed since the batch started (their size or date no longer
    /// match, or, without a recorded fingerprint, modified after the start). The batch most likely replaced
    /// them just before it stopped, so they are left alone rather than processed a second time.
    public let alreadyReplaced: [URL]
    public let pipeline: Pipeline
    public let mode: OutputMode
    public let problem: Problem?

    /// Overwriting originals is never resumed without the user confirming it again.
    public var needsOverwriteConfirmation: Bool { mode == .overwrite }

    /// `isReadable`, `directoryExists` and `fingerprint` take paths; injected so the plan is testable without
    /// files. Readability, not existence, decides: in the sandbox a file outside the allowed folders can't even be
    /// seen. `refusedFolders`: folders the user was asked for and didn't allow (`AccessPrompt.askToRead`); an
    /// unreadable image inside one is `unopened`. Items are deduplicated by file path (the first stays).
    public static func make(journal: RunJournal, existing: [InputItem], isReadable: (String) -> Bool,
                            directoryExists: (String) -> Bool,
                            fingerprint: (String) -> FileFingerprint? = { FileFingerprint.of(URL(fileURLWithPath: $0)) },
                            refusedFolders: [URL] = [])
        -> ResumePlan {
        let done = Set(journal.completed)
        let remaining = InputItem.unique(journal.inputItems.indices.filter { !done.contains($0) }
            .map { journal.inputItems[$0] })
        let records = Dictionary(journal.items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var toRun: [InputItem] = []
        var missing: [URL] = []
        var unopened: [URL] = []
        var replaced: [URL] = []
        for item in remaining {
            let path = item.source.path
            guard isReadable(path) else {
                let folder = item.source.deletingLastPathComponent()
                if refusedFolders.contains(where: { AccessNeeds.isCovered(folder, by: $0) }) {
                    unopened.append(item.source)
                } else {
                    missing.append(item.source)
                }
                continue
            }
            if journal.outputMode == .overwrite,
               changedSinceStart(records[path], current: fingerprint(path), started: journal.started) {
                replaced.append(item.source)
                continue
            }
            toRun.append(item)
        }
        let known = Set(existing.map(\.fileKey))
        var problem: Problem?
        if toRun.isEmpty {
            problem = .nothingLeft
        } else if case .newFolder(let folder) = journal.outputMode, !directoryExists(folder.path) {
            problem = .outputFolderMissing(folder)
        }
        return ResumePlan(toRun: toRun, toAdd: toRun.filter { !known.contains($0.fileKey) }, missing: missing,
                          unopened: unopened, alreadyReplaced: replaced, pipeline: journal.pipeline,
                          mode: journal.outputMode, problem: problem)
    }

    /// True when the recorded fingerprint no longer matches, or, without one (older journals), when the file was
    /// modified after the batch started.
    static func changedSinceStart(_ record: RunJournal.Item?, current: FileFingerprint?, started: Date) -> Bool {
        if let matches = record?.matches(current) { return !matches }
        guard let current else { return false }
        return current.modified > started.timeIntervalSince1970
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
