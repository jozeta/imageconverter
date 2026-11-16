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
        let formats = [pipeline.output.format] + pipeline.extraOutputs.map(\.settings.format)
        if let missing = formats.first(where: { !environment.writableFormats.contains($0) }) {
            environment.err("imageconverter: this Mac can't write \(missing.displayName).")
            return CLIExit.usage
        }
        for note in pipeline.loadNotes.notes {
            environment.err("imageconverter: warning: \(ReportExporter.printable(note))")
        }

        warnAboutIgnoredFlags(options, format: pipeline.output.format, environment: environment)
        let missing = options.inputs.filter { !FileManager.default.fileExists(atPath: $0) }
        for path in missing { environment.err("imageconverter: No such file: \(path)") }
        let items = InputCollector.collect(options.inputs.filter { !missing.contains($0) }
            .map { URL(fileURLWithPath: $0) })
        let mode = outputMode(options)
        announceExtraOutputs(pipeline, mode: mode, environment: environment)
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
            // Folders named on the command line or in a file passed to it are used as given (announced above).
            await BatchRunner.run(items, pipeline: pipeline, mode: mode, trash: environment.trash,
                                  control: environment.control, presets: PresetLibrary.folder(environment.presetDirectory),
                                  variantFolders: .trustPaths, progress: progress)
        }
        var report = ProcessingReport(batch: batch, total: items.count, outputMode: mode.kind.rawValue,
                                      presetName: presetName, startedAt: started, finishedAt: Date())
        add(missing: missing, to: &report)
        return CLIRunner.finish(report, format: options.json ? .json : options.report,
                                interrupted: batch.cancelled, environment: environment)
    }

    /// Where every extra output writes, said on stderr before anything runs (a preset or file can name any folder).
    static func announceExtraOutputs(_ pipeline: Pipeline, mode: OutputMode, environment: CLIEnvironment) {
        for variant in pipeline.extraOutputs {
            environment.err("Extra output “\(ReportExporter.printable(variant.displayName))” → "
                            + ReportExporter.printable(variant.folderDescription(main: mode)))
        }
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
            pipeline.presetName = preset.name
            presetName = preset.name
        } else if let path = options.pipelineFile {
            do { pipeline = try PipelineFile.load(URL(fileURLWithPath: path)) } catch let error as PresetError {
                throw CLIUsageError("Can't use pipeline file '\(path)': \(error.reason)")
            }
        }
        return (applyOverrides(options, to: pipeline), presetName)
    }

    /// The flags win over the preset or file: format, quality, size cap, longest edge and metadata removal
    /// (`PipelineOverrides`, shared with the Shortcuts actions).
    static func applyOverrides(_ options: ConvertOptions, to base: Pipeline) -> Pipeline {
        PipelineOverrides(format: options.format, quality: options.quality, maxSizeBytes: options.maxSizeBytes,
                          longEdge: options.resizeLongEdge, variants: options.variants, stripGPS: options.stripGPS,
                          stripAll: options.stripAll).applied(to: base)
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
                                   presets: PresetLibrary.folder(environment.presetDirectory), variantFolders: .trustPaths)
        }
        guard let planned else { return CLIExit.interrupted }
        let entries = planned.flatMap { file -> [ReportEntry] in
            [entry(for: file)] + file.variants.map { variant in
                ReportEntry(source: file.source.path, destination: variant.destination.path, status: .succeeded,
                            inputBytes: nil, variant: variant.variant.displayName)
            }
        }
        let images = entries.filter { $0.variant == nil }
        let summary = RunSummary(
            startedAt: started, finishedAt: Date(), outputMode: mode.kind.rawValue, total: images.count,
            succeeded: images.filter { $0.status == .succeeded }.count, failed: 0,
            skipped: images.filter { $0.status == .skipped }.count, inputBytes: 0, outputBytes: 0)
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
                let lead = entry.variant.map { "  + \(ReportExporter.printable($0)):" }
                    ?? ReportExporter.printable(entry.source)
                environment.out(lead + target + note)
            }
            let extras = entries.count - images.count
            let more = extras > 0 ? " (and \(extras) extra \(extras == 1 ? "output" : "outputs"))" : ""
            environment.out("\(report.summary.succeeded) of \(report.summary.total) files would be written\(more).")
        }
        if report.summary.failed > 0 { return CLIExit.someFailed }
        return report.summary.total == 0 ? CLIExit.nothingToDo : CLIExit.success
    }

    /// The dry run's line for an item's primary output.
    private static func entry(for file: PlannedFile) -> ReportEntry {
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

    /// What overwrite mode does to the original: "replace" in place, or "replace (original to Trash)" when the
    /// name or format changes. Nil outside overwrite mode.
    static func overwriteNote(_ file: PlannedFile) -> String? {
        if file.trashesSource { return "replace (original to Trash)" }
        return file.replacesSource ? "replace" : nil
    }
}
