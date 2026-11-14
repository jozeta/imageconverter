import Foundation

/// What starts a job.
public enum JobTrigger: Codable, Equatable, Sendable {
    /// Only when the user runs it.
    case manual
    /// Whenever a new or changed file has settled in one of its input folders.
    case watch
    /// Every `every` seconds (at least `JobSchedule.minimumInterval`).
    case schedule(every: TimeInterval)
}

/// The file a job writes next to its outputs after each run that processed files.
public enum ReportFormat: String, Codable, CaseIterable, Sendable {
    case csv, json, text, html

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        case .text: return "txt"
        case .html: return "html"
        }
    }
}

/// A saved automation: which folders, which pipeline (its own copy or a linked preset's current one),
/// where the outputs go, and what starts it.
public struct Job: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// The job's own pipeline; ignored while `presetID` is set.
    public var pipeline: Pipeline
    /// When set, the preset's pipeline at run time is used (preset automation).
    public var presetID: UUID?
    /// Input folders.
    public var inputs: [URL]
    public var recursive: Bool
    public var output: OutputMode
    public var trigger: JobTrigger
    public var report: ReportFormat?
    public var isEnabled: Bool

    public static let schemaVersion = 1

    public init(id: UUID = UUID(), name: String, pipeline: Pipeline = Pipeline(), presetID: UUID? = nil,
                inputs: [URL] = [], recursive: Bool = false, output: OutputMode, trigger: JobTrigger = .manual,
                report: ReportFormat? = nil, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.pipeline = pipeline
        self.presetID = presetID
        self.inputs = inputs
        self.recursive = recursive
        self.output = output
        self.trigger = trigger
        self.report = report
        self.isEnabled = isEnabled
    }

    /// The pipeline to run: the linked preset's current one, or the job's own. Nil when the linked preset is gone.
    public func resolvedPipeline(presets: [Preset]) -> Pipeline? {
        guard let presetID else { return pipeline }
        return presets.first { $0.id == presetID }?.pipeline
    }

    /// The new-folder output: it may lie inside an input folder, and must never be read back as input.
    public var excludedFolders: [URL] {
        guard case .newFolder(let root) = output else { return [] }
        return [root]
    }
}

/// Everything about a job except its id and name, as stored in the `payload` of its template file.
public struct JobSettings: Codable, Equatable, Sendable {
    public static let maxInputs = 64

    public var schemaVersion: Int
    public var pipeline: Pipeline
    public var presetID: UUID?
    public var inputs: [URL]
    public var recursive: Bool
    public var output: OutputMode
    public var trigger: JobTrigger
    public var report: ReportFormat?
    public var isEnabled: Bool

    public init(_ job: Job) {
        schemaVersion = Job.schemaVersion
        pipeline = job.pipeline
        presetID = job.presetID
        inputs = job.inputs
        recursive = job.recursive
        output = job.output
        trigger = job.trigger
        report = job.report
        isEnabled = job.isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pipeline, presetID, inputs, recursive, output, trigger, report, isEnabled
    }

    /// Job files are untrusted: only absolute file URLs, a bounded number of inputs, and a sane schedule.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion <= Job.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Unsupported job version")
        }
        pipeline = try container.decode(Pipeline.self, forKey: .pipeline)
        presetID = try container.decodeIfPresent(UUID.self, forKey: .presetID)
        inputs = try container.decode([URL].self, forKey: .inputs)
        guard inputs.count <= Self.maxInputs, inputs.allSatisfy(Self.isLocalFolderURL) else {
            throw DecodingError.dataCorruptedError(forKey: .inputs, in: container, debugDescription: "Invalid inputs")
        }
        recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        output = try container.decode(OutputMode.self, forKey: .output)
        if case .newFolder(let root) = output, !Self.isLocalFolderURL(root) {
            throw DecodingError.dataCorruptedError(forKey: .output, in: container, debugDescription: "Invalid output")
        }
        let trigger = try container.decode(JobTrigger.self, forKey: .trigger)
        if case .schedule(let every) = trigger {
            guard every.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .trigger, in: container,
                                                       debugDescription: "Invalid schedule")
            }
            self.trigger = .schedule(every: JobSchedule.clamped(every))
        } else {
            self.trigger = trigger
        }
        report = try container.decodeIfPresent(ReportFormat.self, forKey: .report)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    static func isLocalFolderURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0")
    }
}

extension Job {
    public init(template: Template<JobSettings>) {
        let settings = template.payload
        self.init(id: template.id, name: template.name, pipeline: settings.pipeline, presetID: settings.presetID,
                  inputs: settings.inputs, recursive: settings.recursive, output: settings.output,
                  trigger: settings.trigger, report: settings.report, isEnabled: settings.isEnabled)
    }

    public var template: Template<JobSettings> {
        Template(id: id, name: name, payload: JobSettings(self))
    }
}

/// When scheduled jobs run.
public enum JobSchedule {
    /// Five minutes: a shorter schedule would mostly re-scan unchanged folders.
    public static let minimumInterval: TimeInterval = 300
    /// Thirty days.
    public static let maximumInterval: TimeInterval = 30 * 86_400

    public static func clamped(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return minimumInterval }
        return min(max(interval, minimumInterval), maximumInterval)
    }

    /// The next run after `date` (the last run, or the moment the schedule started).
    public static func nextRun(after date: Date, interval: TimeInterval) -> Date {
        date.addingTimeInterval(clamped(interval))
    }
}

/// Jobs as `jobs/<id>.json` (through the hardened `TemplateStore`) and their processed-file ledgers as
/// `jobs/<id>.ledger.json` (the store skips those: their names aren't UUIDs).
public final class JobStore: @unchecked Sendable {
    /// 100 000 inputs and 100 000 outputs with long paths fit; anything larger is not ours.
    static let maxLedgerFileSize = 256 * 1_048_576

    public let directory: URL
    private let templates: TemplateStore<JobSettings>
    private let ledgerLock = NSLock()

    public init(directory: URL = TemplateStore<JobSettings>.defaultDirectory(folder: "jobs")) {
        self.directory = directory
        templates = TemplateStore(directory: directory, noun: "job")
    }

    /// The jobs by name, plus the files that were skipped and why.
    public func load() -> (jobs: [Job], skipped: [(file: String, reason: String)]) {
        let result = templates.load()
        return (result.templates.map(Job.init(template:)), result.skipped)
    }

    /// Saves (or replaces) a job; the name is validated and must be unique.
    public func save(_ job: Job) throws {
        var stored = job
        if case .schedule(let every) = job.trigger { stored.trigger = .schedule(every: JobSchedule.clamped(every)) }
        // The same rules as loading, so a saved job is never skipped on the next load.
        guard stored.inputs.count <= JobSettings.maxInputs,
              stored.inputs.allSatisfy(JobSettings.isLocalFolderURL) else {
            throw PresetError.invalidStructure
        }
        if case .newFolder(let root) = stored.output, !JobSettings.isLocalFolderURL(root) {
            throw PresetError.invalidStructure
        }
        try templates.save(stored.template)
    }

    public func rename(id: UUID, to name: String) throws {
        try templates.rename(id: id, to: name)
    }

    /// Deletes the job and its ledger.
    public func delete(id: UUID) throws {
        try templates.delete(id: id)
        try resetLedger(id: id)
    }

    // MARK: Ledgers

    public func ledgerURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).ledger.json", isDirectory: false)
    }

    /// The job's ledger; empty when there is none yet. Throws when one exists but can't be trusted, so a
    /// job never silently reprocesses (and in overwrite mode re-compresses) every file.
    public func loadLedger(id: UUID) throws -> ProcessedLedger {
        ledgerLock.lock()
        defer { ledgerLock.unlock() }
        let url = ledgerURL(for: id)
        // lstat: a dangling link is still "there" (and then rejected), only a missing file means "none yet".
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT { return ProcessedLedger() }
        let data = try StoredFile.readData(url, maxSize: Self.maxLedgerFileSize)
        do {
            return try JSONDecoder().decode(ProcessedLedger.self, from: data)
        } catch {
            throw StoredFile.decodeError(error)
        }
    }

    public func saveLedger(_ ledger: ProcessedLedger, id: UUID) throws {
        ledgerLock.lock()
        defer { ledgerLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: ledgerURL(for: id), options: .atomic)
    }

    /// Forgets every processed file, so the next run processes everything again.
    public func resetLedger(id: UUID) throws {
        ledgerLock.lock()
        defer { ledgerLock.unlock() }
        do {
            try FileManager.default.removeItem(at: ledgerURL(for: id))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        }
    }
}
