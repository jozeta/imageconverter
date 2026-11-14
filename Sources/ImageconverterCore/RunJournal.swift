import Foundation

/// A record of a running batch, so a run interrupted by a crash or a forced quit can be offered again on the
/// next launch. Written when the run starts, updated as items finish, and deleted when the run ends normally
/// or is cancelled: a journal that is still there means the app never got to the end.
public struct RunJournal: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Large enough for 100 000 paths; the file is untrusted on read, like presets.
    public static let maxFileSize = 32 * 1_048_576
    public static let maxItems = 100_000

    public struct Item: Codable, Equatable, Sendable {
        public var path: String
        public var relativeDirectory: String

        public init(path: String, relativeDirectory: String) {
            self.path = path
            self.relativeDirectory = relativeDirectory
        }
    }

    public var schemaVersion: Int
    public var id: UUID
    public var started: Date
    public var items: [Item]
    public var pipeline: Pipeline
    public var outputMode: OutputMode
    /// Indices into `items` that were written or skipped by a condition, ascending. Failed items aren't
    /// completed: a resumed run tries them again. Stored in the file as `[first, last]` runs, so a finished
    /// stretch of 100 000 files is one pair.
    public var completed: [Int]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, started, items, pipeline, outputMode, completed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        started = try container.decode(Date.self, forKey: .started)
        items = try container.decode([Item].self, forKey: .items)
        pipeline = try container.decode(Pipeline.self, forKey: .pipeline)
        outputMode = try container.decode(OutputMode.self, forKey: .outputMode)
        let runs = try container.decode([[Int]].self, forKey: .completed)
        guard let indices = Self.expand(runs, count: items.count) else {
            throw DecodingError.dataCorruptedError(forKey: .completed, in: container,
                                                   debugDescription: "Invalid completed ranges")
        }
        completed = indices
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(started, forKey: .started)
        try container.encode(items, forKey: .items)
        try container.encode(pipeline, forKey: .pipeline)
        try container.encode(outputMode, forKey: .outputMode)
        try container.encode(Self.runs(completed), forKey: .completed)
    }

    /// Consecutive indices as `[first, last]` pairs (duplicates collapse).
    static func runs(_ indices: [Int]) -> [[Int]] {
        var runs: [[Int]] = []
        for index in Set(indices).sorted() {
            if let last = runs.last?.last, index == last + 1 {
                runs[runs.count - 1][1] = index
            } else {
                runs.append([index, index])
            }
        }
        return runs
    }

    /// The indices of `runs`, or nil unless every run is a `[first, last]` pair inside `0..<count`, ascending
    /// and not touching the one before (so a hostile file can't make the list larger than `count`).
    static func expand(_ runs: [[Int]], count: Int) -> [Int]? {
        var indices: [Int] = []
        var previous = -2
        for run in runs {
            guard run.count == 2, run[0] <= run[1], run[0] > previous + 1, run[1] < count else { return nil }
            indices.append(contentsOf: run[0]...run[1])
            previous = run[1]
        }
        return indices
    }

    public init(items: [InputItem], pipeline: Pipeline, mode: OutputMode, started: Date = Date()) {
        schemaVersion = Self.currentVersion
        id = UUID()
        self.started = started
        self.items = items.map { Item(path: $0.source.path, relativeDirectory: $0.relativeDirectory) }
        self.pipeline = pipeline
        outputMode = mode
        completed = []
    }

    public var inputItems: [InputItem] {
        items.map { InputItem(source: URL(fileURLWithPath: $0.path), relativeDirectory: $0.relativeDirectory) }
    }

    /// What a resumed run would process: the items not completed, in their original order.
    public var remainingItems: [InputItem] {
        let done = Set(completed)
        return inputItems.enumerated().filter { !done.contains($0.offset) }.map(\.element)
    }

    /// `Application Support/imageconverter/journal.json` (inside the app's container when sandboxed).
    public static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("imageconverter", isDirectory: true)
            .appendingPathComponent("journal.json")
    }

    /// The journal of a run that didn't finish, or nil when there is none or it isn't a valid journal (not a
    /// regular file, too large, malformed, a newer version, or inconsistent paths and indices).
    public static func pending(at url: URL? = defaultURL) -> RunJournal? {
        guard let url, let data = try? StoredFile.readData(url, maxSize: maxFileSize),
              let journal = try? JSONDecoder().decode(RunJournal.self, from: data), journal.isValid else { return nil }
        return journal
    }

    /// Deletes the journal (after the user resumed or dismissed it).
    public static func discard(at url: URL? = defaultURL) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes atomically, creating the folder when needed.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    private var isValid: Bool {
        guard schemaVersion == Self.currentVersion, items.count <= Self.maxItems,
              items.allSatisfy({ Self.isValidPath($0.path) && Self.isValidText($0.relativeDirectory) }),
              completed.allSatisfy(items.indices.contains) else {
            return false
        }
        if case .newFolder(let folder) = outputMode { return folder.isFileURL && Self.isValidPath(folder.path) }
        return true
    }

    private static func isValidPath(_ path: String) -> Bool {
        path.hasPrefix("/") && isValidText(path)
    }

    private static func isValidText(_ text: String) -> Bool {
        text.utf8.count <= 4096 && !text.unicodeScalars.contains { $0.value == 0 }
    }
}

/// Keeps the journal of one run up to date. Completions are recorded in a bitmap (cheap on the batch's
/// collecting side) and written on a background serial queue: after 20 new ones, or at most a second after
/// the first unsaved one, whichever comes first, coalescing everything in between.
final class RunJournalWriter: @unchecked Sendable {
    static let batchSize = 20

    private let url: URL
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "imageconverter.run-journal", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var journal: RunJournal
    private var done: [Bool]
    private var unsaved = 0
    private var timerScheduled = false
    private var urgentQueued = false
    private var removed = false

    init(url: URL, journal: RunJournal, interval: TimeInterval = 1) {
        self.url = url
        self.journal = journal
        self.interval = interval
        done = Array(repeating: false, count: journal.items.count)
        for index in journal.completed where done.indices.contains(index) { done[index] = true }
    }

    /// Writes the current state before returning (the run's start). A journal that can't be written doesn't
    /// stop the run; it only can't be recovered.
    func writeNow() {
        queue.sync { flush(force: true) }
    }

    func markCompleted(_ index: Int) {
        lock.lock()
        guard done.indices.contains(index), !done[index], !removed else {
            lock.unlock()
            return
        }
        done[index] = true
        unsaved += 1
        let urgent = unsaved >= Self.batchSize && !urgentQueued
        let startTimer = !timerScheduled
        urgentQueued = urgentQueued || urgent
        timerScheduled = true
        lock.unlock()
        if urgent {
            queue.async { self.flush() }
        }
        if startTimer {
            queue.asyncAfter(deadline: .now() + interval) {
                self.lock.lock()
                self.timerScheduled = false
                self.lock.unlock()
                self.flush()
            }
        }
    }

    /// Waits for writes already queued (tests).
    func waitForWrites() {
        queue.sync {}
    }

    /// Deletes the journal; nothing is written after this.
    func remove() {
        queue.sync {
            lock.lock()
            removed = true
            lock.unlock()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// On `queue`: one write with everything recorded so far.
    private func flush(force: Bool = false) {
        lock.lock()
        guard !removed, force || unsaved > 0 else {
            lock.unlock()
            return
        }
        journal.completed = done.indices.filter { done[$0] }
        let snapshot = journal
        unsaved = 0
        urgentQueued = false
        lock.unlock()
        try? snapshot.write(to: url)
    }
}

/// Temp files a crash left behind: `FileCommitter` writes `.imageconverter-<UUID>.tmp` next to each destination
/// and moves it into place at once, so one that is over an hour old belongs to no running write.
enum StaleTempFiles {
    static let maxAge: TimeInterval = 3600

    /// Every folder the planned outputs go into, once each, in plan order.
    static func folders(for plans: [PlannedOutput]) -> [URL] {
        var seen = Set<String>()
        return plans.map { $0.destination.deletingLastPathComponent().standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
    }

    /// True only for the exact pattern, with an uppercase UUID as `UUID().uuidString` writes it.
    static func matches(_ name: String) -> Bool {
        let prefix = FileCommitter.tempPrefix
        let suffix = ".tmp"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let middle = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: middle)?.uuidString == middle
    }

    /// Removes matching regular files (never folders or links) older than `maxAge` directly in `folders`.
    static func remove(in folders: [URL], now: Date = Date()) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where matches(name) {
                let url = folder.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      values.isSymbolicLink != true, let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) > maxAge else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
