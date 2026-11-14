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

    init(directory: URL, maxRuns: Int = RunHistory.maxRuns) {
        self.directory = directory
        self.maxRuns = maxRuns
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: RunHistory] = [:]

    /// The one instance for a directory, so every writer shares one lock. The first caller's `maxRuns` wins.
    public static func shared(directory: URL = RunHistory.defaultDirectory, maxRuns: Int = RunHistory.maxRuns) -> RunHistory {
        registryLock.lock()
        defer { registryLock.unlock() }
        let key = directory.standardizedFileURL.path
        if let existing = registry[key] { return existing }
        let history = RunHistory(directory: directory, maxRuns: maxRuns)
        registry[key] = history
        return history
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("imageconverter", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false) }
    private func summaryURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).summary.json", isDirectory: false)
    }

    /// The small companion file listings read instead of the (possibly large) full record.
    private struct SummaryFile: Codable {
        var schemaVersion: Int
        var summary: RunSummary
    }
    private static let maxSummarySize = 65_536

    private func writeSummary(_ summary: RunSummary) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let file = SummaryFile(schemaVersion: RunRecord.currentSchema, summary: summary)
        try? encoder.encode(file).write(to: summaryURL(summary.id), options: .atomic)
    }

    private func removeFiles(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: summaryURL(id))
    }

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
        writeSummary(report.summary)
        prune()
    }

    private func prune() {
        let runs = loadSummaries()
        guard runs.count > maxRuns else { return }
        for old in runs.dropFirst(maxRuns) { removeFiles(old.id) }
    }

    private static func newerFirst(_ lhs: RunSummary, _ rhs: RunSummary) -> Bool {
        lhs.finishedAt != rhs.finishedAt ? lhs.finishedAt > rhs.finishedAt : lhs.id.uuidString < rhs.id.uuidString
    }

    private func loadSummary(name: String) -> RunSummary? {
        let suffix = ".summary.json"
        guard name.hasSuffix(suffix), let id = UUID(uuidString: String(name.dropLast(suffix.count))),
              id.uuidString + suffix == name,
              let data = try? StoredFile.readData(directory.appendingPathComponent(name), maxSize: Self.maxSummarySize) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(SummaryFile.self, from: data), file.schemaVersion == RunRecord.currentSchema,
              file.summary.id == id, Self.isPlausible(file.summary) else { return nil }
        return file.summary
    }

    /// Valid summaries, newest first, read from the small files only. A full record without a summary (written by
    /// an older build, or the summary was lost) is decoded once and its summary written.
    private func loadSummaries() -> [RunSummary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let fileManager = FileManager.default
        var summaries: [UUID: RunSummary] = [:]
        for name in names {
            guard let summary = loadSummary(name: name), fileManager.fileExists(atPath: fileURL(summary.id).path) else {
                continue
            }
            summaries[summary.id] = summary
        }
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(".summary.json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))), summaries[id] == nil,
                  let record = load(name: name) else { continue }
            writeSummary(record.summary)
            summaries[id] = record.summary
        }
        return summaries.values.sorted(by: Self.newerFirst)
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

    private static func isPlausible(_ record: RunRecord) -> Bool {
        record.entries.count <= maxEntries && isPlausible(record.summary)
    }

    private static func isPlausible(_ summary: RunSummary) -> Bool {
        let counts = [summary.total, summary.succeeded, summary.failed, summary.skipped, summary.unchanged,
                      summary.cancelled, summary.inputBytes, summary.outputBytes]
        return counts.allSatisfy { $0 >= 0 }
            && summary.finishedAt >= summary.startedAt
            && summary.averageDuration.isFinite && (summary.averageRatio?.isFinite ?? true)
    }

    /// Summaries, newest first; `jobName` keeps only that job's runs (job summaries are history filtered by job).
    public func summaries(jobName: String? = nil) -> [RunSummary] {
        lock.lock()
        defer { lock.unlock() }
        return loadSummaries().filter { jobName == nil || $0.jobName == jobName }
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
        removeFiles(id)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for run in loadSummaries() { removeFiles(run.id) }
    }
}
