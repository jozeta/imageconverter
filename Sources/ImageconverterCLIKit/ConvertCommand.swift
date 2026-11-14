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

        let items = InputCollector.collect(options.inputs.map { URL(fileURLWithPath: $0) })
        let mode = outputMode(options)
        if case .newFolder(let folder) = mode, !options.dryRun {
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                environment.err("imageconverter: can't create \(folder.path): \(error.localizedDescription)")
                return CLIExit.someFailed
            }
        }
        let started = Date()
        if options.dryRun { return dryRun(items, pipeline: pipeline, mode: mode, options: options, environment: environment) }

        let quiet = options.quiet || options.json
        let batch = await BatchRunner.run(
            items, pipeline: pipeline, mode: mode, trash: environment.trash,
            progress: CLIRunner.progressReporter(quiet: quiet, environment: environment))
        let report = ProcessingReport(batch: batch, total: items.count, outputMode: mode.kind.rawValue,
                                      presetName: presetName, startedAt: started, finishedAt: Date())
        return CLIRunner.finish(report, format: options.json ? .json : options.report, environment: environment)
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
            if options.stripAll { pipeline.metadata.removeAll = true }
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

    /// Lists the destinations the plain naming rules give (renaming and conditions are not evaluated); writes nothing.
    private static func dryRun(_ items: [InputItem], pipeline: Pipeline, mode: OutputMode, options: ConvertOptions,
                               environment: CLIEnvironment) -> Int32 {
        let plans = OutputPlanner.plan(items, format: pipeline.output.format, mode: mode)
        let entries = zip(items, plans).map { item, plan in
            ReportEntry(source: item.source.path, destination: plan.destination.path, status: .succeeded,
                        inputBytes: nil, note: "dry run")
        }
        if options.json {
            environment.out(JSONOutput.string(["dryRun": true, "files": entries.map {
                ["source": $0.source, "destination": $0.destination ?? ""]
            }]))
        } else {
            for entry in entries {
                environment.out("\(ReportExporter.printable(entry.source)) -> "
                                + ReportExporter.printable(entry.destination ?? ""))
            }
            environment.out("Dry run: \(items.count) files would be converted. Nothing was written.")
        }
        return items.isEmpty ? CLIExit.nothingToDo : CLIExit.success
    }
}
