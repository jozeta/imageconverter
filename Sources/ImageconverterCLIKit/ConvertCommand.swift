import Foundation
import ImageconverterCore

enum ConvertCommand {
    static func run(_ options: ConvertOptions, environment: CLIEnvironment) async -> Int32 {
        let pipeline: Pipeline
        let presetName: String?
        do {
            (pipeline, presetName) = try resolvePipeline(options, environment: environment)
        } catch let error as CLIUsageError {
            environment.err("imageconverter: \(error.message)")
            return CLIExit.usage
        } catch {
            environment.err("imageconverter: \(error)")
            return CLIExit.usage
        }
        guard OutputFormat.available().contains(pipeline.output.format) else {
            environment.err("imageconverter: this Mac can't write \(pipeline.output.format.displayName).")
            return CLIExit.usage
        }

        warnAboutIgnoredFlags(options, format: pipeline.output.format, environment: environment)
        let missing = options.inputs.filter { !FileManager.default.fileExists(atPath: $0) }
        for path in missing { environment.err("imageconverter: No such file: \(path)") }
        let items = InputCollector.collect(options.inputs.filter { !missing.contains($0) }
            .map { URL(fileURLWithPath: $0) })
        let mode = outputMode(options)
        if options.dryRun {
            return await dryRun(Setup(items: items, missing: missing, pipeline: pipeline, mode: mode),
                                options: options, environment: environment)
        }
        if case .newFolder(let folder) = mode {
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                environment.err("imageconverter: can't create \(folder.path): \(error.localizedDescription)")
                return CLIExit.someFailed
            }
        }
        let started = Date()
        let progress = CLIRunner.progressReporter(quiet: options.quiet || options.json, environment: environment)
        let batch = await environment.cancel.run {
            await BatchRunner.run(items, pipeline: pipeline, mode: mode, trash: environment.trash,
                                  control: environment.control, presets: PresetLibrary.folder(environment.presetDirectory),
                                  progress: progress)
        }
        var report = ProcessingReport(batch: batch, total: items.count, outputMode: mode.kind.rawValue,
                                      presetName: presetName, startedAt: started, finishedAt: Date())
        add(missing: missing, to: &report)
        return CLIRunner.finish(report, format: options.json ? .json : options.report,
                                interrupted: batch.cancelled, environment: environment)
    }

    /// A path that doesn't exist counts as a failed file, so a typo can't end in a quiet "success".
    static func add(missing: [String], to report: inout ProcessingReport) {
        for path in missing {
            report.entries.append(ReportEntry(source: path, status: .failed, inputBytes: nil, note: "No such file"))
        }
        report.summary.total += missing.count
        report.summary.failed += missing.count
    }

    /// Flags the chosen format ignores are said out loud instead of silently doing nothing.
    static func warnAboutIgnoredFlags(_ options: ConvertOptions, format: OutputFormat, environment: CLIEnvironment) {
        guard !format.supportsQuality else { return }
        if options.quality != nil {
            environment.err("imageconverter: warning: --quality has no effect on \(format.displayName).")
        }
        if options.maxSizeBytes != nil {
            environment.err("imageconverter: warning: --max-size has no effect on \(format.displayName); "
                            + "choose a format with a quality setting (jpeg, heic, avif, jpeg2000).")
        }
    }

    static func outputMode(_ options: ConvertOptions) -> OutputMode {
        if let folder = options.outputDirectory {
            return .newFolder(URL(fileURLWithPath: folder, isDirectory: true))
        }
        if options.sameFolder { return .sameFolder(suffix: options.suffix ?? OutputPlanner.defaultSuffix) }
        return .overwrite
    }

    // MARK: pipeline

    static func resolvePipeline(_ options: ConvertOptions, environment: CLIEnvironment) throws -> (Pipeline, String?) {
        var pipeline = Pipeline()
        var presetName: String?
        if let name = options.preset {
            let loaded = PresetStore(directory: environment.presetDirectory).loadAll()
            guard let preset = loaded.presets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw CLIUsageError("No preset named '\(name)'. Run 'imageconverter presets list'.")
            }
            pipeline = preset.pipeline
            presetName = preset.name
        } else if let path = options.pipelineFile {
            do { pipeline = try PipelineFile.load(URL(fileURLWithPath: path)) } catch let error as PresetError {
                throw CLIUsageError("Can't use pipeline file '\(path)': \(error.reason)")
            }
        }
        return (applyOverrides(options, to: pipeline), presetName)
    }

    /// The flags win over the preset or file: format, quality, size cap, longest edge and metadata removal.
    static func applyOverrides(_ options: ConvertOptions, to base: Pipeline) -> Pipeline {
        var pipeline = base
        if let format = options.format { pipeline.output.format = format }
        if let quality = options.quality { pipeline.output.quality = quality }
        if let bytes = options.maxSizeBytes { pipeline.output.compression = .maxSize(bytes: bytes) }
        if let edge = options.resizeLongEdge { setLongestEdge(edge, in: &pipeline) }
        if options.stripGPS || options.stripAll {
            pipeline.metadata.isEnabled = true
            pipeline.metadata.isIncluded = true
            if options.stripGPS { pipeline.metadata.location = .remove }
            if options.stripAll {
                // Really everything: the preset's "keep when removing all" list doesn't apply.
                pipeline.metadata.removeAll = true
                pipeline.metadata.keepWhenRemovingAll = []
            }
        }
        return pipeline
    }

    private static func setLongestEdge(_ edge: Int, in pipeline: inout Pipeline) {
        if let index = pipeline.steps.firstIndex(where: { $0.operation.kind == .resize }),
           case .resize(var resize) = pipeline.steps[index].operation {
            resize.mode = .longestEdge(edge)
            pipeline.steps[index].operation = .resize(resize)
            pipeline.steps[index].isEnabled = true
        } else {
            pipeline.steps.insert(PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(edge)))), at: 0)
        }
    }

    // MARK: dry run

    /// Plans with the batch's own path (conditions, rename templates, collision names); writes nothing.
    private struct Setup {
        let items: [InputItem]
        let missing: [String]
        let pipeline: Pipeline
        let mode: OutputMode
    }

    private static func dryRun(_ setup: Setup, options: ConvertOptions, environment: CLIEnvironment) async -> Int32 {
        let (items, missing, pipeline, mode) = (setup.items, setup.missing, setup.pipeline, setup.mode)
        let started = Date()
        let planned = await environment.cancel.run {
            await BatchRunner.plan(items, pipeline: pipeline, mode: mode,
                                   presets: PresetLibrary.folder(environment.presetDirectory))
        }
        guard let planned else { return CLIExit.interrupted }
        let entries = planned.map { file -> ReportEntry in
            switch file.disposition {
            case .skip:
                return ReportEntry(source: file.source.path, status: .skipped, inputBytes: nil,
                                   note: ConditionalStep.skippedReason)
            case .copyOriginal:
                // A copy in place is left as it is (nothing replaced); a renamed copy moves the original.
                let moved = file.trashesSource ? overwriteNote(file) : nil
                let note = ([ConditionalStep.copiedNote] + [moved].compactMap { $0 }).joined(separator: "; ")
                return ReportEntry(source: file.source.path, destination: file.destination?.path, status: .succeeded,
                                   inputBytes: nil, note: note)
            case .process:
                return ReportEntry(source: file.source.path, destination: file.destination?.path, status: .succeeded,
                                   inputBytes: nil, note: overwriteNote(file))
            }
        }
        let summary = RunSummary(
            startedAt: started, finishedAt: Date(), outputMode: mode.kind.rawValue, total: entries.count,
            succeeded: entries.filter { $0.status == .succeeded }.count, failed: 0,
            skipped: entries.filter { $0.status == .skipped }.count, inputBytes: 0, outputBytes: 0)
        var report = ProcessingReport(summary: summary, entries: entries)
        add(missing: missing, to: &report)
        environment.err("Dry run: nothing is written.")
        if let format = options.json ? .json : options.report {
            let text = String(bytes: ReportExporter.data(report, format: format), encoding: .utf8) ?? ""
            environment.out(text.hasSuffix("\n") ? String(text.dropLast()) : text)
        } else {
            for entry in entries {
                let target = entry.destination.map { " -> " + ReportExporter.printable($0) } ?? ""
                let note = entry.note.map { " (\(ReportExporter.printable($0)))" } ?? ""
                environment.out(ReportExporter.printable(entry.source) + target + note)
            }
            environment.out("\(report.summary.succeeded) of \(report.summary.total) files would be written.")
        }
        if report.summary.failed > 0 { return CLIExit.someFailed }
        return report.summary.total == 0 ? CLIExit.nothingToDo : CLIExit.success
    }

    /// What overwrite mode does to the original: "replace" in place, or "replace (original to Trash)" when the
    /// name or format changes. Nil outside overwrite mode.
    static func overwriteNote(_ file: PlannedFile) -> String? {
        if file.trashesSource { return "replace (original to Trash)" }
        return file.replacesSource ? "replace" : nil
    }
}
