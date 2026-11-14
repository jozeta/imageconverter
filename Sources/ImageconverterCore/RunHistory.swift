import Foundation

/// A stored run: its summary and entries (capped), as one file `history/<id>.json`.
public struct RunRecord: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var summary: RunSummary
    public var entries: [ReportEntry]
    /// True when the run had more entries than `RunHistory.maxEntries` and the rest were dropped.
    public var entriesTruncated: Bool

    public var report: ProcessingReport { ProcessingReport(summary: summary, entries: entries) }
}

/// Past runs, newest kept: the latest `maxRuns` (100) runs, each with at most `maxEntries` (5000) entries.
/// Files in the folder are untrusted: they are opened without following links, size-capped, name-checked against
/// the run id they contain, and sanity-checked; anything else is ignored.
public final class RunHistory: @unchecked Sendable {
    public static let maxRuns = 100
    public static let maxEntries = 5000
    static let maxFileSize = 16 * 1_048_576

    private let directory: URL
    private let maxRuns: Int
    private let lock = NSLock()

    public init(directory: URL = RunHistory.defaultDirectory, maxRuns: Int = RunHistory.maxRuns) {
        self.directory = directory
        self.maxRuns = maxRuns
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("imageconverter", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false) }

    /// Stores the run (replacing one with the same id), then deletes the oldest beyond the limit.
    public func save(_ report: ProcessingReport) throws {
        lock.lock()
        defer { lock.unlock() }
        let record = RunRecord(schemaVersion: RunRecord.currentSchema, summary: report.summary,
                               entries: Array(report.entries.prefix(Self.maxEntries)),
                               entriesTruncated: report.entries.count > Self.maxEntries)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: fileURL(report.summary.id), options: .atomic)
        prune()
    }

    private func prune() {
        let runs = loadAll()
        guard runs.count > maxRuns else { return }
        for old in runs.sorted(by: Self.newerFirst).dropFirst(maxRuns) {
            try? FileManager.default.removeItem(at: fileURL(old.summary.id))
        }
    }

    private static func newerFirst(_ lhs: RunRecord, _ rhs: RunRecord) -> Bool {
        lhs.summary.finishedAt != rhs.summary.finishedAt ? lhs.summary.finishedAt > rhs.summary.finishedAt
            : lhs.summary.id.uuidString < rhs.summary.id.uuidString
    }

    private func load(name: String) -> RunRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))),
              id.uuidString + ".json" == name,
              let data = try? StoredFile.readData(directory.appendingPathComponent(name), maxSize: Self.maxFileSize),
              let record = try? decoder.decode(RunRecord.self, from: data),
              record.schemaVersion == RunRecord.currentSchema, record.summary.id == id,
              Self.isPlausible(record) else { return nil }
        return record
    }

    /// Valid runs, newest first; unreadable, oversized, mismatched or implausible files are skipped.
    private func loadAll() -> [RunRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap(load(name:)).sorted(by: Self.newerFirst)
    }

    private static func isPlausible(_ record: RunRecord) -> Bool {
        let summary = record.summary
        let counts = [summary.total, summary.succeeded, summary.failed, summary.skipped, summary.unchanged,
                      summary.cancelled, summary.inputBytes, summary.outputBytes]
        return counts.allSatisfy { $0 >= 0 } && record.entries.count <= maxEntries
            && summary.finishedAt >= summary.startedAt
            && summary.averageDuration.isFinite && (summary.averageRatio?.isFinite ?? true)
    }

    /// Summaries, newest first; `jobName` keeps only that job's runs (job summaries are history filtered by job).
    public func summaries(jobName: String? = nil) -> [RunSummary] {
        lock.lock()
        defer { lock.unlock() }
        return loadAll().map(\.summary).filter { jobName == nil || $0.jobName == jobName }
    }

    /// One run with its entries; nil when missing or invalid.
    public func record(id: UUID) -> RunRecord? {
        lock.lock()
        defer { lock.unlock() }
        return load(name: fileURL(id).lastPathComponent)
    }

    public func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for run in loadAll() { try? FileManager.default.removeItem(at: fileURL(run.summary.id)) }
    }
}
