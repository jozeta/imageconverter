import Foundation

/// How one file ended.
public enum ReportStatus: String, Codable, Equatable, Sendable {
    case succeeded, failed, skipped, cancelled
}

/// One file in a run report.
public struct ReportEntry: Codable, Equatable, Sendable {
    public var source: String
    public var destination: String?
    public var status: ReportStatus
    /// Nil when the size couldn't be read.
    public var inputBytes: Int?
    public var outputBytes: Int?
    /// Seconds the worker spent on the file (0 when not timed, e.g. skipped files).
    public var duration: Double
    public var inputWidth: Int?
    public var inputHeight: Int?
    public var outputWidth: Int?
    public var outputHeight: Int?
    /// A note on a written file, or the reason a file failed.
    public var note: String?
    /// The extra output's label; nil for the primary output (and for failed or skipped files).
    public var variant: String?

    public init(source: String, destination: String? = nil, status: ReportStatus, inputBytes: Int?,
                outputBytes: Int? = nil, duration: Double = 0, inputWidth: Int? = nil, inputHeight: Int? = nil,
                outputWidth: Int? = nil, outputHeight: Int? = nil, note: String? = nil, variant: String? = nil) {
        self.source = source
        self.destination = destination
        self.status = status
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.duration = duration
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.note = note
        self.variant = variant
    }

    /// Output size divided by input size; nil unless the file was written from a non-empty source.
    public var ratio: Double? {
        guard status == .succeeded, let outputBytes, let inputBytes, inputBytes > 0 else { return nil }
        return Double(outputBytes) / Double(inputBytes)
    }

    public var name: String { (source as NSString).lastPathComponent }
}

/// Totals for one run.
public struct RunSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var jobName: String?
    public var presetName: String?
    public var outputMode: String
    public var total: Int
    public var succeeded: Int
    public var failed: Int
    /// Left alone by a condition.
    public var skipped: Int
    /// Jobs only: left alone because they hadn't changed since they were processed.
    public var unchanged: Int
    public var cancelled: Int
    public var inputBytes: Int
    public var outputBytes: Int

    public var savedBytes: Int { inputBytes - outputBytes }
    public var totalDuration: Double { finishedAt.timeIntervalSince(startedAt) }
    /// Output over input for the written files; nil when nothing was written.
    public var overallRatio: Double? { succeeded > 0 && inputBytes > 0 ? Double(outputBytes) / Double(inputBytes) : nil }
    public var averageDuration: Double
    /// Mean of the per-file output/input ratios over succeeded files; nil when there are none.
    public var averageRatio: Double?

    public init(id: UUID = UUID(), startedAt: Date, finishedAt: Date, jobName: String? = nil, presetName: String? = nil,
                outputMode: String, total: Int, succeeded: Int, failed: Int, skipped: Int = 0, unchanged: Int = 0, cancelled: Int = 0,
                inputBytes: Int, outputBytes: Int, averageDuration: Double = 0, averageRatio: Double? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.jobName = jobName
        self.presetName = presetName
        self.outputMode = outputMode
        self.total = total
        self.succeeded = succeeded
        self.failed = failed
        self.skipped = skipped
        self.unchanged = unchanged
        self.cancelled = cancelled
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.averageDuration = averageDuration
        self.averageRatio = averageRatio
    }
}

/// A run's summary and its per-file entries: the one model the toast, the sidebar report, jobs and exports share.
public struct ProcessingReport: Equatable, Sendable {
    public var summary: RunSummary
    public var entries: [ReportEntry]

    public init(summary: RunSummary, entries: [ReportEntry]) {
        self.summary = summary
        self.entries = entries
    }

    /// Builds the report from a finished batch. `total` is the number of items the run was given.
    public init(batch: BatchReport, total: Int, outputMode: String, presetName: String? = nil, jobName: String? = nil,
                startedAt: Date = Date(), finishedAt: Date = Date()) {
        // No I/O here: every size was read by the runner. Entries go back into input order.
        var byName: [URL: [ReportEntry]] = [:]
        for entry in batch.entries {
            byName[entry.source, default: []].append(ReportEntry(
                source: entry.source.path, destination: entry.destination.path, status: .succeeded,
                inputBytes: entry.inputBytes, outputBytes: entry.outputBytes, duration: entry.duration,
                inputWidth: entry.inputWidth, inputHeight: entry.inputHeight, outputWidth: entry.outputWidth,
                outputHeight: entry.outputHeight, note: entry.note, variant: entry.variant))
        }
        for failure in batch.failures {
            byName[failure.source, default: []].append(ReportEntry(
                source: failure.source.path, status: .failed, inputBytes: failure.inputBytes,
                duration: failure.duration, note: failure.reason))
        }
        for skip in batch.skipped {
            byName[skip.source, default: []].append(ReportEntry(
                source: skip.source.path, status: .skipped, inputBytes: skip.inputBytes, note: skip.reason))
        }
        var entries: [ReportEntry] = []
        var seen: Set<URL> = []
        for source in batch.order where seen.insert(source).inserted { entries += byName[source] ?? [] }
        // A hand-built BatchReport has no order: keep written then failed.
        if batch.order.isEmpty {
            var listed: Set<URL> = []
            entries = batch.entries.filter { listed.insert($0.source).inserted }
                .flatMap { written in (byName[written.source] ?? []).filter { $0.status == .succeeded } }
                + batch.failures.map { failure in ReportEntry(source: failure.source.path, status: .failed,
                                                        inputBytes: failure.inputBytes, duration: failure.duration,
                                                        note: failure.reason) }
                + batch.skipped.map { ReportEntry(source: $0.source.path, status: .skipped, inputBytes: $0.inputBytes,
                                                  note: $0.reason) }
        }
        // Counts and averages are per image: extra outputs are rows of their own, but not more images.
        let primaries = entries.filter { $0.variant == nil }
        let ratios = primaries.compactMap(\.ratio)
        let done = batch.convertedCount + batch.failures.count + batch.skipped.count
        let notRun = batch.cancelled ? max(0, total - done) : 0
        let times = primaries.filter { $0.status == .succeeded }.map(\.duration)
        let summary = RunSummary(
            startedAt: startedAt, finishedAt: finishedAt, jobName: jobName, presetName: presetName,
            outputMode: outputMode, total: total, succeeded: batch.convertedCount, failed: batch.failures.count,
            skipped: batch.skipped.count, cancelled: notRun, inputBytes: batch.inputBytes, outputBytes: batch.outputBytes,
            averageDuration: times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count),
            averageRatio: ratios.isEmpty ? nil : ratios.reduce(0, +) / Double(ratios.count))
        self.init(summary: summary, entries: entries)
    }
}

extension ProcessingReport {
    /// The files this run wrote that still exist (Reveal Outputs). `exists` is injectable for tests.
    public func existingOutputs(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [URL] {
        entries.compactMap { entry in
            guard entry.status == .succeeded, let path = entry.destination, exists(path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}

/// Size and percentage text shared by the estimate line, the preview table, the toast and the report.
public enum SizeFormat {
    public static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// "−74 %" when smaller, "+12 %" when larger, "0 %" when the rounded change is zero. Nil when `before` is 0.
    public static func percentChange(from before: Int, to after: Int) -> String? {
        guard before > 0 else { return nil }
        let value = (Double(after - before) / Double(before) * 100).rounded()
        if value == 0 { return "0 %" }
        return value < 0 ? "\u{2212}\(Int(-value)) %" : "+\(Int(value)) %"
    }

    /// "saved 31.2 MB (62 %)", "grew by 1.1 MB (12 %)" or "same size"; nil when nothing was written.
    public static func savedPhrase(input: Int, output: Int) -> String? {
        guard input > 0 else { return nil }
        if input == output { return "same size" }
        let percent = Int((Double(abs(input - output)) / Double(input) * 100).rounded())
        if output > input { return "grew by \(bytes(output - input)) (\(percent) %)" }
        return "saved \(bytes(input - output)) (\(percent) %)"
    }
}

extension ProcessingReport {
    /// This report with every source and destination path written relative to `folder` (`a.jpg`, `sub/a.jpg`,
    /// `../Drop/a.jpg`), for a report file saved in that folder.
    public func relativized(to folder: URL) -> ProcessingReport {
        var copy = self
        let base = folder.standardizedFileURL.pathComponents
        copy.entries = entries.map { entry in
            var entry = entry
            entry.source = Self.relative(entry.source, from: base)
            entry.destination = entry.destination.map { Self.relative($0, from: base) }
            return entry
        }
        return copy
    }

    static func relative(_ path: String, from base: [String]) -> String {
        guard path.hasPrefix("/") else { return path }
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var common = 0
        while common < min(base.count, parts.count), base[common] == parts[common] { common += 1 }
        let parents = Array(repeating: "..", count: base.count - common)
        return (parents + parts[common...]).joined(separator: "/")
    }
}
