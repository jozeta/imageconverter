import Foundation
import ImageconverterCore

enum PresetsCommand {
    static func list(json: Bool, environment: CLIEnvironment) -> Int32 {
        let loaded = PresetStore(directory: environment.presetDirectory).loadAll()
        for skipped in loaded.skipped { environment.err("skipped preset file \(skipped.file): \(skipped.reason)") }
        if json {
            let rows = loaded.presets.map { ["name": $0.name, "builtIn": $0.isBuiltIn] as [String: Any] }
            environment.out(JSONOutput.string(["presets": rows]))
        } else {
            for preset in loaded.presets { environment.out(preset.name + (preset.isBuiltIn ? " (built-in)" : "")) }
        }
        return CLIExit.success
    }
}

enum JobsCommand {
    private static func store(_ environment: CLIEnvironment) -> JobStore { JobStore(directory: environment.jobDirectory) }

    static func list(json: Bool, environment: CLIEnvironment) -> Int32 {
        let loaded = store(environment).load()
        for skipped in loaded.skipped { environment.err("skipped job file \(skipped.file): \(skipped.reason)") }
        if json {
            let rows = loaded.jobs.map { ["name": $0.name, "enabled": $0.isEnabled] as [String: Any] }
            environment.out(JSONOutput.string(["jobs": rows]))
        } else {
            for job in loaded.jobs { environment.out(job.name + (job.isEnabled ? "" : " (disabled)")) }
        }
        return CLIExit.success
    }

    static func run(name: String, quiet: Bool, json: Bool, environment: CLIEnvironment) async -> Int32 {
        let jobStore = store(environment)
        guard let job = jobStore.load().jobs.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            environment.err("imageconverter: No job named '\(name)'. Run 'imageconverter jobs list'.")
            return CLIExit.usage
        }
        let presets = PresetStore(directory: environment.presetDirectory)
        let progress = CLIRunner.progressReporter(quiet: quiet, environment: environment)
        let result = await environment.cancel.run {
            await JobRunner.run(job, store: jobStore, presetStore: presets, trash: environment.trash,
                                progress: progress)
        }
        return CLIRunner.finish(result.report, format: json ? .json : nil, problem: result.problem,
                                interrupted: result.batch.cancelled, environment: environment)
    }
}

enum JSONOutput {
    static func string(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]))
            ?? Data("{}".utf8)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}
