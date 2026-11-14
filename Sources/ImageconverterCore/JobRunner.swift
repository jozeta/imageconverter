import Foundation

/// What one job run did.
public struct JobRunResult: Sendable {
    public var batch: BatchReport
    public var report: ProcessingReport
    /// Candidates left alone because this exact version was already processed (or written by the job).
    public var unchanged: Int
    /// The report file written, if the job has one and the run processed files.
    public var reportFile: URL?
    /// A problem with the run as a whole (linked preset gone, ledger unreadable, report not written).
    public var problem: String?
}

public enum JobRunner {
    /// Runs `job` over `files` (from a watcher; each must lie in one of the job's folders) or, when nil, over
    /// everything in its folders. Files whose current version is in the ledger are skipped; the rest go through
    /// `BatchRunner`, then the processed sources and the written files are recorded (so a job's own outputs are
    /// never inputs, and a bad file isn't retried until it changes) and the report file is written.
    public static func run(
        _ job: Job,
        files: [URL]? = nil,
        store: JobStore,
        presetStore: PresetStore? = nil,
        maxPixels: Int = 250_000_000,
        trash: @escaping Trasher = systemTrash,
        now: @Sendable () -> Date = { Date() },
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in }
    ) async -> JobRunResult {
        let startedAt = now()
        func finish(_ batch: BatchReport, total: Int, unchanged: Int, problem: String?) -> JobRunResult {
            var report = ProcessingReport(batch: batch, total: total, outputMode: job.output.kind.rawValue,
                                          jobName: job.name, startedAt: startedAt, finishedAt: now())
            report.summary.skipped = unchanged
            report.summary.total += unchanged
            return JobRunResult(batch: batch, report: report, unchanged: unchanged, reportFile: nil, problem: problem)
        }

        let presets = presetStore?.loadAll().presets ?? PresetStore.builtIns
        guard let pipeline = job.resolvedPipeline(presets: presets) else {
            return finish(BatchReport(), total: 0, unchanged: 0, problem: "The job's preset no longer exists.")
        }
        var ledger: ProcessedLedger
        do { ledger = try store.loadLedger(id: job.id) } catch {
            return finish(BatchReport(), total: 0, unchanged: 0,
                          problem: "The list of processed files couldn't be read. Reset it to process every file again.")
        }

        var items: [InputItem] = []
        var fingerprints: [URL: FileFingerprint] = [:]
        var unchanged = 0
        for item in candidates(for: job, files: files) {
            guard let fingerprint = FileFingerprint.of(item.source) else { continue }
            if ledger.contains(fingerprint) {
                unchanged += 1
            } else {
                items.append(item)
                fingerprints[item.source] = fingerprint
            }
        }
        guard !items.isEmpty else { return finish(BatchReport(), total: 0, unchanged: unchanged, problem: nil) }

        let batch = await BatchRunner.run(items, pipeline: pipeline, mode: job.output, maxPixels: maxPixels,
                                          trash: trash, progress: progress)
        // Sources first (as they were before the run), then what was written: in overwrite mode the written file
        // is the source path's new version and must win.
        var processed = batch.order.compactMap { fingerprints[$0] }
        processed += batch.written.compactMap(FileFingerprint.of)
        ledger.record(processed)
        var problems: [String] = []
        do { try store.saveLedger(ledger, id: job.id) } catch {
            problems.append("The list of processed files couldn't be saved: \(error.localizedDescription)")
        }

        var result = finish(batch, total: items.count, unchanged: unchanged, problem: nil)
        if let format = job.report, let folder = reportFolder(for: job) {
            do {
                result.reportFile = try writeReport(result.report, format: format, in: folder, date: startedAt)
            } catch {
                problems.append("The report couldn't be written: \(error.localizedDescription)")
            }
        }
        result.problem = problems.isEmpty ? nil : problems.joined(separator: " ")
        return result
    }

    // MARK: Inputs

    /// The job's image files: the given files that belong to it, or everything in its folders (top level only
    /// unless recursive). Hidden files, temp files and anything in the output folder are never inputs.
    public static func candidates(for job: Job, files: [URL]?) -> [InputItem] {
        let filter = WatchFilter(folders: job.inputs, recursive: job.recursive, excluded: job.excludedFolders)
        let found: [InputItem]
        if let files {
            // Real paths, so they compare with the filter's roots; InputCollector keeps only images.
            found = InputCollector.collect(files.map { URL(fileURLWithPath: WatchFilter.canonicalPath($0)) })
        } else if job.recursive {
            found = InputCollector.collect(job.inputs)
        } else {
            found = InputCollector.collect(job.inputs.flatMap(topLevelFiles))
        }
        return found
            .filter { filter.accepts(WatchFilter.canonicalPath($0.source)) }
            .map { item in
                // Loose files have no folder; give them the input folder's name like a dropped folder would.
                guard item.relativeDirectory.isEmpty else { return item }
                return InputItem(source: item.source,
                                 relativeDirectory: item.source.deletingLastPathComponent().lastPathComponent)
            }
    }

    private static func topLevelFiles(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    // MARK: Report file

    /// The new-folder output, or the first input folder for same-folder and overwrite jobs.
    public static func reportFolder(for job: Job) -> URL? {
        if case .newFolder(let root) = job.output { return root }
        return job.inputs.first
    }

    /// `imageconverter-report-2026-11-14_093000.csv` (local time); `_2`, `_3`, ... when that name is taken.
    public static func reportFileName(date: Date, format: ReportFormat, number: Int = 1) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let suffix = number > 1 ? "_\(number)" : ""
        return "imageconverter-report-\(formatter.string(from: date))\(suffix).\(format.fileExtension)"
    }

    /// Written to a temp file and moved into place without replacing anything.
    static func writeReport(_ report: ProcessingReport, format: ReportFormat, in folder: URL, date: Date) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent("\(FileCommitter.tempPrefix)\(UUID().uuidString).tmp")
        try ReportExporter.data(report, format: format).write(to: temp, options: [.withoutOverwriting])
        defer { try? files.removeItem(at: temp) }
        for number in 1...1000 {
            let destination = folder.appendingPathComponent(reportFileName(date: date, format: format, number: number))
            do {
                try files.moveItem(at: temp, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
