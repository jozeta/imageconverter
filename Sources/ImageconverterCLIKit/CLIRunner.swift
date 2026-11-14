import Foundation
import ImageconverterCore

/// Runs a parsed command. The executable is a thin wrapper around `CLIRunner.main`.
public enum CLIRunner {
    /// Parses and runs `arguments` (without the program name); returns the exit code. `--data-dir DIR` (anywhere
    /// before `--`) reads presets and jobs from DIR instead of the environment's folders.
    public static func main(_ given: [String], environment: CLIEnvironment = .standard()) async -> Int32 {
        var environment = environment
        let arguments: [String]
        do {
            let extracted = try CLIDataDirectory.extract(given)
            arguments = extracted.arguments
            if let directory = extracted.dataDirectory {
                environment = environment.with(dataDirectory: CLIDataDirectory.resolve(home: CLIDataDirectory.realHome,
                                                                                       override: directory))
            }
        } catch let error as CLIUsageError {
            environment.err("imageconverter: \(error.message)")
            environment.err("Run 'imageconverter --help' for usage.")
            return CLIExit.usage
        } catch {
            return CLIExit.usage
        }
        switch CLIParser.parse(arguments) {
        case .failure(let error):
            environment.err("imageconverter: \(error.message)")
            environment.err("Run 'imageconverter --help' for usage.")
            return CLIExit.usage
        case .success(let command):
            return await run(command, environment: environment)
        }
    }

    public static func run(_ command: CLICommand, environment: CLIEnvironment) async -> Int32 {
        switch command {
        case .help:
            environment.out(CLIText.usage)
            return CLIExit.success
        case .version:
            environment.out("imageconverter \(AppInfo.version)")
            return CLIExit.success
        case .convert(let options):
            return await ConvertCommand.run(options, environment: environment)
        case .presetsList(let json):
            return PresetsCommand.list(json: json, environment: environment)
        case .jobsList(let json):
            return JobsCommand.list(json: json, environment: environment)
        case .jobsRun(let name, let quiet, let json):
            return await JobsCommand.run(name: name, quiet: quiet || json, json: json, environment: environment)
        }
    }

    /// Prints a finished run: the JSON or chosen report, else a short summary. Returns the exit code.
    static func finish(_ report: ProcessingReport, format: ReportFormat?, problem: String? = nil,
                       interrupted: Bool = false, environment: CLIEnvironment) -> Int32 {
        if let problem { environment.err("imageconverter: \(problem)") }
        if let format {
            let text = String(bytes: ReportExporter.data(report, format: format), encoding: .utf8) ?? ""
            environment.out(text.hasSuffix("\n") ? String(text.dropLast()) : text)
        } else {
            let summary = report.summary
            var line = "\(summary.succeeded) of \(summary.total) files converted"
            if summary.failed > 0 { line += ", \(summary.failed) failed" }
            if summary.skipped > 0 { line += ", \(summary.skipped) skipped" }
            if summary.unchanged > 0 { line += ", \(summary.unchanged) unchanged" }
            if let phrase = SizeFormat.savedPhrase(input: summary.inputBytes, output: summary.outputBytes),
               summary.succeeded > 0 { line += " (\(phrase))" }
            environment.out(line)
            for entry in report.entries where entry.status == .failed {
                environment.out("failed: \(ReportExporter.printable(entry.source)): "
                                + ReportExporter.printable(entry.note ?? "unknown error"))
            }
        }
        if interrupted {
            environment.err("Interrupted: \(report.summary.cancelled) files were not started.")
            return CLIExit.interrupted
        }
        if problem != nil || report.summary.failed > 0 { return CLIExit.someFailed }
        return report.summary.total == 0 ? CLIExit.nothingToDo : CLIExit.success
    }

    /// A progress callback that writes "[3/10]" lines to stderr unless quiet.
    static func progressReporter(quiet: Bool, environment: CLIEnvironment) -> @Sendable (BatchProgress) -> Void {
        guard !quiet else { return { _ in } }
        return { progress in
            environment.err("[\(progress.completed)/\(progress.total)]"
                            + (progress.failed > 0 ? " \(progress.failed) failed" : ""))
        }
    }
}
