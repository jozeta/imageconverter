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
    /// completed: a resumed run tries them again.
    public var completed: [Int]

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
              Set(completed).count == completed.count, completed.allSatisfy(items.indices.contains) else {
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

/// Keeps the journal of one run up to date: completions are written in groups (every 20 items, or when a
/// second has passed since the last write), on the batch's collecting side.
final class RunJournalWriter {
    static let batchSize = 20
    static let interval: TimeInterval = 1

    private let url: URL
    private var journal: RunJournal
    private var unsaved = 0
    private var lastWrite: Date
    private let now: () -> Date

    init(url: URL, journal: RunJournal, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.journal = journal
        self.now = now
        lastWrite = now()
    }

    /// A journal that can't be written doesn't stop the run; it only can't be recovered.
    func writeNow() {
        try? journal.write(to: url)
        unsaved = 0
        lastWrite = now()
    }

    func markCompleted(_ index: Int) {
        let position = journal.completed.firstIndex { $0 > index } ?? journal.completed.endIndex
        guard position == journal.completed.startIndex || journal.completed[position - 1] != index else { return }
        journal.completed.insert(index, at: position)
        unsaved += 1
        if unsaved >= Self.batchSize || now().timeIntervalSince(lastWrite) >= Self.interval { writeNow() }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Temp files a crash left behind: `FileCommitter` writes `.imageconverter-<UUID>.tmp` next to each destination
/// and moves it into place at once, so one that is over an hour old belongs to no running write.
enum StaleTempFiles {
    static let maxAge: TimeInterval = 3600

    /// The folders a run writes into: the chosen folder, or the sources' folders.
    static func folders(for items: [InputItem], mode: OutputMode) -> [URL] {
        if case .newFolder(let root) = mode { return [root.standardizedFileURL] }
        var seen = Set<String>()
        return items.map { $0.source.deletingLastPathComponent().standardizedFileURL }
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
