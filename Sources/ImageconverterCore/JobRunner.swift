import Foundation

/// What one job run did.
public struct JobRunResult: Sendable {
    public var batch: BatchReport
    public var report: ProcessingReport
    /// Candidates left alone: this exact version was processed, given up on, or written by the job.
    public var unchanged: Int
    /// Candidates still being written (changed less than `stableFor` ago, or not readable yet); not recorded,
    /// so the next run looks at them again.
    public var waiting: Int
    /// The report file written, if the job has one and the run processed files.
    public var reportFile: URL?
    /// A problem with the run as a whole (linked preset gone, ledger unreadable, report not written).
    public var problem: String?
}

public enum JobRunner {
    /// How long a file must be unchanged before a scan takes it, like `FolderWatcher`'s readiness rule.
    public static let stableFor: TimeInterval = 2

    /// Runs `job` over `files` (from a watcher; each must lie in one of the job's folders) or, when nil, over
    /// everything in its folders that changed at least `stableFor` seconds before `now` and is readable (a file
    /// still being copied waits for the next run). Settled files (see `ProcessedLedger`) are skipped; the rest go
    /// through `BatchRunner`. Then successes (copies and files a condition skipped included) are recorded as done,
    /// failures count an attempt (after `ProcessedLedger.maxAttempts` an unchanged file is given up on, which the
    /// report says once), written files are recorded as outputs (never inputs), and the report file is written.
    /// Background runs pass a lower `concurrency` and `memoryBudgetPixels`, so they share the Mac with a manual run.
    public static func run(
        _ job: Job,
        files: [URL]? = nil,
        store: JobStore,
        presetStore: PresetStore? = nil,
        maxPixels: Int = 250_000_000,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        memoryBudgetPixels: Int = BatchRunner.defaultMemoryBudgetPixels,
        trash: @escaping Trasher = systemTrash,
        now: @Sendable () -> Date = { Date() },
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in }
    ) async -> JobRunResult {
        let startedAt = now()
        func finish(_ batch: BatchReport, total: Int, selection: Selection, problem: String?) -> JobRunResult {
            var report = ProcessingReport(batch: batch, total: total, outputMode: job.output.kind.rawValue,
                                          jobName: job.name, startedAt: startedAt, finishedAt: now())
            // Counted apart from files a condition skipped.
            report.summary.unchanged = selection.unchanged
            report.summary.total += selection.unchanged
            return JobRunResult(batch: batch, report: report, unchanged: selection.unchanged,
                                waiting: selection.waiting, reportFile: nil, problem: problem)
        }

        let presets = presetStore?.loadAll().presets ?? PresetStore.builtIns
        guard let pipeline = job.resolvedPipeline(presets: presets) else {
            return finish(BatchReport(), total: 0, selection: Selection(), problem: "The job's preset no longer exists.")
        }
        var ledger: ProcessedLedger
        do { ledger = try store.loadLedger(id: job.id) } catch {
            return finish(BatchReport(), total: 0, selection: Selection(),
                          problem: "The list of processed files couldn't be read. Reset it to process every file again.")
        }

        let selection = select(candidates(for: job, files: files), ledger: ledger,
                               stableBefore: files == nil ? startedAt.addingTimeInterval(-stableFor) : nil)
        guard !selection.items.isEmpty else {
            return finish(BatchReport(), total: 0, selection: selection, problem: nil)
        }

        let batch = await BatchRunner.run(selection.items, pipeline: pipeline, mode: job.output, maxPixels: maxPixels,
                                          concurrency: concurrency, memoryBudgetPixels: memoryBudgetPixels,
                                          trash: trash, progress: progress)
        let gaveUp = update(&ledger, with: batch, fingerprints: selection.fingerprints)
        var problems: [String] = []
        do { try store.saveLedger(ledger, id: job.id) } catch {
            problems.append("The list of processed files couldn't be saved: \(error.localizedDescription)")
        }

        var result = finish(batch, total: selection.items.count, selection: selection, problem: nil)
        for index in result.report.entries.indices where result.report.entries[index].status == .failed
            && gaveUp.contains(result.report.entries[index].source) {
            let reason = result.report.entries[index].note ?? "Failed"
            result.report.entries[index].note = "Gave up after \(ProcessedLedger.maxAttempts) attempts: \(reason)"
        }
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

    struct Selection {
        var items: [InputItem] = []
        var fingerprints: [URL: FileFingerprint] = [:]
        var unchanged = 0
        var waiting = 0
    }

    /// Settled files are counted as unchanged; with `stableBefore`, files modified after it or not readable wait.
    static func select(_ candidates: [InputItem], ledger: ProcessedLedger, stableBefore: Date?) -> Selection {
        var selection = Selection()
        for item in candidates {
            guard let fingerprint = FileFingerprint.of(item.source) else { continue }
            if ledger.isSettled(fingerprint) {
                selection.unchanged += 1
                continue
            }
            if let stableBefore {
                guard let snapshot = FileSnapshot.take(item.source), snapshot.readable,
                      snapshot.modified <= stableBefore else {
                    selection.waiting += 1
                    continue
                }
            }
            selection.items.append(item)
            selection.fingerprints[item.source] = fingerprint
        }
        return selection
    }

    /// Records the run; returns the source paths given up on in this run.
    static func update(_ ledger: inout ProcessedLedger, with batch: BatchReport,
                       fingerprints: [URL: FileFingerprint]) -> Set<String> {
        let failed = Set(batch.failures.map(\.source))
        var gaveUp: Set<String> = []
        // Sources as they were before the run (in overwrite mode the path's new version is an output).
        ledger.recordProcessed(batch.order.filter { !failed.contains($0) }.compactMap { fingerprints[$0] })
        for source in batch.failures.map(\.source) {
            guard let fingerprint = fingerprints[source] else { continue }
            if ledger.recordFailure(fingerprint) >= ProcessedLedger.maxAttempts { gaveUp.insert(source.path) }
        }
        ledger.recordOutputs(batch.written.compactMap(FileFingerprint.of))
        return gaveUp
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
        let temp = FileCommitter.beginTemp(in: folder)
        // Before the write: a failed write must not leave a partial temp file behind either.
        defer {
            try? files.removeItem(at: temp)
            FileCommitter.endTemp(temp)
        }
        try ReportExporter.data(report, format: format).write(to: temp, options: [.withoutOverwriting])
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
