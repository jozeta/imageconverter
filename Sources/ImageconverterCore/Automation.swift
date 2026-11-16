import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a Shortcuts action couldn't do its work, in words for the user (Shortcuts shows `message`).
public enum AutomationError: Error, Equatable, Sendable {
    case noFiles
    case noImages
    case formatNotWritable(String)
    case invalidLongEdge(Int)
    case invalidQuality(Int)
    /// The sandboxed app can't use the folder: it must be allowed in Help ▸ Folder Access first.
    case folderNotAllowed(path: String)
    case notAFolder(path: String)
    case unreadableFile(name: String)
    /// A file Shortcuts passed as data (not a location) is bigger than the decode limit.
    case fileTooLarge(name: String, limit: Int)
    case nothingWritten(String)
    case cancelled

    public var message: String {
        switch self {
        case .noFiles: return "No files were given to the action."
        case .noImages: return "None of the given files is an image imageconverter can read."
        case .formatNotWritable(let format): return "This Mac can't write \(format) files."
        case .invalidLongEdge(let edge):
            return "The long edge must be between 1 and \(Automation.maxLongEdge) pixels (it was \(edge))."
        case .invalidQuality(let quality): return "The quality must be between 1 and 100 (it was \(quality))."
        case .folderNotAllowed(let path):
            return "imageconverter isn't allowed to use the folder \(path). Open imageconverter, choose "
                + "Help \u{25B8} Folder Access\u{2026} \u{25B8} Add Folder\u{2026}, allow the folder, then run the shortcut again."
        case .notAFolder(let path): return "\(path) isn't a folder."
        case .unreadableFile(let name): return "imageconverter couldn't read the file \(name)."
        case .fileTooLarge(let name, let limit):
            return "The file \(name) is larger than \(SizeFormat.bytes(limit)), the most imageconverter reads."
        case .nothingWritten(let reason): return "No image was converted. \(reason)"
        case .cancelled: return "The action was cancelled."
        }
    }
}

/// What a Shortcuts action asks for: a preset (or none) and the settings that win over it.
public struct AutomationRequest: Equatable, Sendable {
    public var preset: Preset?
    public var overrides: PipelineOverrides

    public init(preset: Preset? = nil, overrides: PipelineOverrides = PipelineOverrides()) {
        self.preset = preset
        self.overrides = overrides
    }

    /// Convert Images / Apply Preset to Folder: the preset, optionally with another format.
    public static func convert(preset: Preset, format: OutputFormat?) -> AutomationRequest {
        AutomationRequest(preset: preset, overrides: PipelineOverrides(format: format))
    }

    /// Strip Metadata: everything removed; each image keeps its format (JPEG and HEIC image data is copied untouched).
    public static func stripMetadata() -> AutomationRequest {
        AutomationRequest(overrides: PipelineOverrides(stripAll: true))
    }

    /// Resize Images: the longest edge in pixels; each image keeps its format.
    public static func resize(longEdge: Int) throws -> AutomationRequest {
        guard (1...Automation.maxLongEdge).contains(longEdge) else { throw AutomationError.invalidLongEdge(longEdge) }
        return AutomationRequest(overrides: PipelineOverrides(longEdge: longEdge))
    }

    /// Convert Format: another format, with a quality of 1–100 for formats that have one (nil: the default).
    public static func convertFormat(_ format: OutputFormat, qualityPercent: Int?) throws -> AutomationRequest {
        if let qualityPercent, !(1...100).contains(qualityPercent) {
            throw AutomationError.invalidQuality(qualityPercent)
        }
        return AutomationRequest(overrides: PipelineOverrides(format: format,
                                                              quality: qualityPercent.map { Double($0) / 100 }))
    }

    /// No preset and no format: every image is written in its own format (`Automation.sourceFormat`).
    public var keepsSourceFormat: Bool { preset == nil && overrides.format == nil }

    /// The pipeline for images whose own format is `sourceFormat` (used only when `keepsSourceFormat`).
    public func pipeline(sourceFormat: OutputFormat) -> Pipeline {
        var base = preset?.pipeline ?? Pipeline()
        if let preset { base.presetName = preset.name }
        if keepsSourceFormat { base.output.format = sourceFormat }
        return overrides.applied(to: base)
    }
}

/// What a finished action did.
public struct AutomationResult: Equatable, Sendable {
    public var written: [URL]
    public var failures: [BatchFailure]
    public var skipped: Int
    /// Every batch of the action as one report (one batch per output format when images keep their own), for
    /// History.
    public var batch = BatchReport()
    /// The images the action was given (after expanding folders).
    public var total = 0

    public init(written: [URL] = [], failures: [BatchFailure] = [], skipped: Int = 0) {
        self.written = written
        self.failures = failures
        self.skipped = skipped
    }

    /// The History entry: labelled "Shortcuts" (with the preset's name), in the output folder's mode.
    public func processingReport(request: AutomationRequest, startedAt: Date, finishedAt: Date = Date())
        -> ProcessingReport {
        ProcessingReport(batch: batch, total: total, outputMode: OutputModeKind.newFolder.rawValue,
                         presetName: request.preset.map { "Shortcuts: \($0.name)" } ?? "Shortcuts",
                         startedAt: startedAt, finishedAt: finishedAt)
    }
}

extension BatchReport {
    /// `other`'s files after this report's (an action that ran several batches).
    mutating func append(_ other: BatchReport) {
        written += other.written
        failures += other.failures
        notes += other.notes
        cancelled = cancelled || other.cancelled
        entries += other.entries
        order += other.order
        skipped += other.skipped
        extraFailures += other.extraFailures
    }
}

/// The Shortcuts actions' logic, shared with nothing UI-related so it is tested without Shortcuts: the files go
/// through `BatchRunner` like the batch, the command line and jobs; the originals are never changed (the
/// output is always a new-folder output, and existing files are never replaced: `_2`, `_3`, …).
public enum Automation {
    public static let maxLongEdge = 100_000
    /// Scratch folders (the files an action returns when no output folder was given) older than this are removed.
    public static let scratchLifetime: TimeInterval = 86_400
    /// Actions are background work like jobs: half the cores and half the memory budget, so a Shortcut started
    /// during a manual batch (or several started by a folder automation) doesn't double the load.
    public static var limits: BatchResourceLimits { .background }

    /// Converts `files` (images or folders of images) into `output`. Throws when there is nothing to convert,
    /// the format can't be written, a folder an extra output writes into beside the originals isn't writable
    /// (`isWritableFolder`), or every image failed (with the first reasons); a run where some images failed returns
    /// the ones that were written. `finished` gets the result of every run that started (for History).
    public static func run(_ files: [URL], request: AutomationRequest, output: URL,
                           presets: PresetLibrary = .standard,
                           writable: [OutputFormat] = OutputFormat.available(),
                           variantFolders: VariantFolderPolicy = .confirmedOnly,
                           limits: BatchResourceLimits = Automation.limits,
                           isWritableFolder: (URL) -> Bool = ExternalRequests.isWritableDirectory,
                           finished: (AutomationResult) -> Void = { _ in })
        async throws -> AutomationResult {
        guard !files.isEmpty else { throw AutomationError.noFiles }
        let items = InputCollector.collect(files)
        guard !items.isEmpty else { throw AutomationError.noImages }
        let grouped = groups(items, request: request, writable: writable)
        // Checked before anything runs: formats, and the originals' folders an extra output writes into.
        for (pipeline, group) in grouped {
            let formats = [pipeline.output.format] + pipeline.extraOutputs.map(\.settings.format)
            if let missing = formats.first(where: { !writable.contains($0) }) {
                throw AutomationError.formatNotWritable(missing.displayName)
            }
            if let folder = foldersBesideOriginals(pipeline, group).first(where: { !isWritableFolder($0) }) {
                throw AutomationError.folderNotAllowed(path: folder.path)
            }
        }
        var result = AutomationResult()
        result.total = items.count
        // Once batches ran, `finished` gets what they did, also when the action then fails or is cancelled.
        defer { finished(result) }
        for (pipeline, group) in grouped {
            let report = await BatchRunner.run(group, pipeline: pipeline, mode: .newFolder(output),
                                               concurrency: limits.concurrency,
                                               memoryBudgetPixels: limits.memoryBudgetPixels, presets: presets,
                                               variantFolders: variantFolders)
            result.written += report.written
            result.failures += report.failures
            result.skipped += report.skipped.count
            result.batch.append(report)
            if report.cancelled || Task.isCancelled {
                result.batch.cancelled = true
                throw AutomationError.cancelled
            }
        }
        if result.written.isEmpty, !result.failures.isEmpty {
            let reasons = result.failures.prefix(3).map { "\($0.source.lastPathComponent): \($0.reason)" }
            let more = result.failures.count > 3 ? " (and \(result.failures.count - 3) more)" : ""
            throw AutomationError.nothingWritten(reasons.joined(separator: "; ") + more)
        }
        return result
    }

    /// The originals' folders that `pipeline`'s extra outputs write into (Same folder as original, a subfolder
    /// there), once each. A file Shortcuts passed gives access to the file, not its folder: such a folder must be
    /// allowed in Folder Access, like an output folder.
    static func foldersBesideOriginals(_ pipeline: Pipeline, _ items: [InputItem]) -> [URL] {
        let beside = pipeline.extraOutputs.contains { variant in
            switch variant.destination {
            case .sameFolder?, .subfolder?: return true
            case .folder?, nil: return false
            }
        }
        guard beside else { return [] }
        var seen = Set<String>()
        return items.map { $0.source.deletingLastPathComponent().standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
    }

    /// The largest file a Shortcuts action copies from data it was handed (the decode limit's file size).
    public static var maxCopiedBytes: Int { DecodeLimits.standard.maxFileBytes }

    /// Throws when data of `count` bytes for the file `name` is over `maxCopiedBytes`.
    public static func checkCopySize(_ count: Int, name: String, limit: Int = maxCopiedBytes) throws {
        if count > limit { throw AutomationError.fileTooLarge(name: name, limit: limit) }
    }

    /// After an action: removes the copies made of files Shortcuts passed as data (with their folders, when
    /// nothing else is in them). The action's outputs stay for the day (`scratchLifetime`), for Shortcuts to read.
    public static func removeCopies(_ copies: [URL]) {
        let manager = FileManager.default
        for copy in copies {
            try? manager.removeItem(at: copy)
            let folder = copy.deletingLastPathComponent()
            if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? manager.removeItem(at: folder)
            }
        }
    }

    /// One pipeline per output format when each image keeps its own; otherwise one for all.
    static func groups(_ items: [InputItem], request: AutomationRequest,
                       writable: [OutputFormat]) -> [(Pipeline, [InputItem])] {
        guard request.keepsSourceFormat else { return [(request.pipeline(sourceFormat: .jpeg), items)] }
        var order: [OutputFormat] = []
        var byFormat: [OutputFormat: [InputItem]] = [:]
        for item in items {
            let format = sourceFormat(of: item.source, writable: writable)
            if byFormat[format] == nil { order.append(format) }
            byFormat[format, default: []].append(item)
        }
        return order.map { (request.pipeline(sourceFormat: $0), byFormat[$0] ?? []) }
    }

    /// The format a file is written back in: its own when this Mac can write it, else PNG for an image with
    /// transparency (when PNG can be written), else JPEG. From the header only.
    public static func sourceFormat(of url: URL, writable: [OutputFormat]) -> OutputFormat {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let type = CGImageSourceGetType(source) as String? else { return .jpeg }
        if let own = OutputFormat.allCases.first(where: { $0.utType.identifier == type }), writable.contains(own) {
            return own
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any]
        let hasAlpha = properties?[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        return hasAlpha && writable.contains(.png) ? .png : .jpeg
    }

    /// `url` as a folder the action may use: it must exist and `isUsable` (readable or writable, after the
    /// caller started any security-scoped access) must hold; otherwise the message points to Folder Access.
    public static func checkedFolder(_ url: URL, isUsable: (URL) -> Bool) throws -> URL {
        let folder = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            throw AutomationError.folderNotAllowed(path: folder.path)
        }
        guard isDirectory.boolValue else { throw AutomationError.notAFolder(path: folder.path) }
        guard isUsable(folder) else { throw AutomationError.folderNotAllowed(path: folder.path) }
        return folder
    }

    /// A new, empty folder under `base` for one action's results; folders there older than `scratchLifetime`
    /// (results Shortcuts has long since copied) are removed first.
    public static func newScratchFolder(in base: URL, now: Date = Date()) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        for old in (try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: keys)) ?? [] {
            let modified = (try? old.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > scratchLifetime { try? manager.removeItem(at: old) }
        }
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// The scratch folders' parent: in the app's temporary folder (inside its container when sandboxed).
    public static var scratchBase: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imageconverter-shortcuts", isDirectory: true)
    }

    /// Get Image Metadata: the file's name, then each metadata group with its fields ("  Label: value"), read
    /// from the header only; values are escaped like in the metadata panel.
    public static func metadataText(of url: URL) throws -> String {
        let inspection = MetadataInspection.read(url)
        if inspection.failure != nil, inspection.entries.isEmpty {
            throw AutomationError.unreadableFile(name: url.lastPathComponent)
        }
        var lines = [MetadataInspection.display(url.lastPathComponent)]
        for group in MetadataGroup.allCases {
            let entries = inspection.entries(in: group)
            guard !entries.isEmpty else { continue }
            lines.append(group.title)
            lines += entries.map { "  \($0.label): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Run Job's result: "Job Web export: Converted 12 · 1 skipped by a condition", "Job Photos: Converted 3
    /// images, 2 unchanged" (files the job had already done), then the run's problem, if any.
    public static func jobSummary(of result: JobRunResult, job: String) -> String {
        let batch = result.batch
        var text = "Job \(job): " + RunCountsText.make(written: batch.convertedCount, skipped: batch.skipped.count,
                                                       failed: batch.failures.count)
        if result.unchanged > 0 { text += ", \(result.unchanged) unchanged" }
        if let problem = result.problem { text += ". \(problem)" }
        return text
    }

    /// The words Shortcuts shows for an error.
    public static func message(for error: Error) -> String {
        if let error = error as? AutomationError { return error.message }
        if let error = error as? ExternalRequestError { return error.message }
        if error is CancellationError { return AutomationError.cancelled.message }
        return error.localizedDescription
    }
}
