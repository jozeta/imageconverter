import Foundation

/// A record of a running batch, so a run interrupted by a crash or a forced quit can be offered again on the
/// next launch. Written when the run starts, updated as items finish, and deleted when the run ends normally
/// or is cancelled: a journal that is still there means the app never got to the end. Each completion is also
/// appended at once to a small completion log next to it (`completionLogURL`), so a crash right after a commit
/// doesn't leave that item looking unfinished. In overwrite mode every item also keeps its source's size and
/// modification date from the start: a resumed run leaves alone a source that no longer matches (it was already
/// replaced), so the pipeline is never applied twice to an original.
public struct RunJournal: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Large enough for 100 000 paths; the file is untrusted on read, like presets.
    public static let maxFileSize = 32 * 1_048_576
    public static let maxItems = 100_000

    public struct Item: Codable, Equatable, Sendable {
        public var path: String
        public var relativeDirectory: String
        /// The source's size and modification date (seconds since 1970) when the run started; overwrite mode
        /// only (nil otherwise, and in older journals).
        public var size: Int?
        public var modified: Double?

        public init(path: String, relativeDirectory: String, size: Int? = nil, modified: Double? = nil) {
            self.path = path
            self.relativeDirectory = relativeDirectory
            self.size = size
            self.modified = modified
        }

        /// False when the file at `path` no longer has the size and date recorded at the start (nil: nothing was
        /// recorded, or the file can't be read).
        func matches(_ current: FileFingerprint?) -> Bool? {
            guard let size, let modified, let current else { return nil }
            return current.size == size && current.modified == modified
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

    /// In overwrite mode each source's fingerprint is read now (`fingerprint`, injectable for tests).
    public init(items: [InputItem], pipeline: Pipeline, mode: OutputMode, started: Date = Date(),
                fingerprint: (URL) -> FileFingerprint? = FileFingerprint.of) {
        schemaVersion = Self.currentVersion
        id = UUID()
        self.started = started
        self.items = items.map { item in
            let print = mode == .overwrite ? fingerprint(item.source) : nil
            return Item(path: item.source.path, relativeDirectory: item.relativeDirectory, size: print?.size,
                        modified: print?.modified)
        }
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
    /// regular file, too large, malformed, a newer version, or inconsistent paths and indices). Completions in
    /// the completion log are added (lines that aren't an index of this journal are ignored).
    public static func pending(at url: URL? = defaultURL) -> RunJournal? {
        guard let url, let data = try? StoredFile.readData(url, maxSize: maxFileSize),
              var journal = try? JSONDecoder().decode(RunJournal.self, from: data), journal.isValid else { return nil }
        let logged = loggedCompletions(at: completionLogURL(for: url), count: journal.items.count)
        if !logged.isEmpty { journal.completed = Array(Set(journal.completed).union(logged)).sorted() }
        return journal
    }

    /// Where the completion log of the journal at `url` is kept.
    public static func completionLogURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".done")
    }

    /// One index per line; untrusted like the journal (size-capped, only indices inside `0..<count`).
    static func loggedCompletions(at url: URL, count: Int) -> Set<Int> {
        guard let data = try? StoredFile.readData(url, maxSize: maxFileSize),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var indices = Set<Int>()
        for line in text.split(separator: "\n") {
            if let index = Int(line), (0..<count).contains(index) { indices.insert(index) }
        }
        return indices
    }

    /// Deletes the journal and its completion log (after the user resumed or dismissed it).
    public static func discard(at url: URL? = defaultURL) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: completionLogURL(for: url))
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

/// Keeps the journal of one run up to date. Each completion is appended at once to the completion log (one
/// short write, so it survives a crash right after the commit), and recorded in a bitmap that is written into
/// the journal itself on a background serial queue: after 20 new ones, or at most a second after the first
/// unsaved one, whichever comes first, coalescing everything in between.
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
    private var log: FileHandle?

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
        queue.sync {
            flush(force: true)
            // A fresh, empty completion log for this run (an old one belongs to the journal this one replaces).
            let logURL = RunJournal.completionLogURL(for: url)
            lock.lock()
            defer { lock.unlock() }
            guard !removed, log == nil,
                  FileManager.default.createFile(atPath: logURL.path, contents: nil) else { return }
            log = try? FileHandle(forWritingTo: logURL)
        }
    }

    func markCompleted(_ index: Int) {
        lock.lock()
        guard done.indices.contains(index), !done[index], !removed else {
            lock.unlock()
            return
        }
        done[index] = true
        try? log?.write(contentsOf: Data("\(index)\n".utf8))
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
            try? log?.close()
            log = nil
            lock.unlock()
            RunJournal.discard(at: url)
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

    /// Removes matching temp files older than `maxAge` directly in `folders` (`FileCommitter.cleanUp`).
    static func remove(in folders: [URL], now: Date = Date()) {
        FileCommitter.cleanUp(in: folders, olderThan: maxAge, now: now)
    }
}
