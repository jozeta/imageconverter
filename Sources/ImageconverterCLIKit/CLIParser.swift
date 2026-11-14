import Foundation
import ImageconverterCore

/// A small hand-written argument parser: `--flag value` and `--flag=value`, no abbreviations.
public enum CLIParser {
    public static let maxResizeEdge = 100_000

    public static func parse(_ arguments: [String]) -> Result<CLICommand, CLIUsageError> {
        do { return .success(try parseThrowing(arguments)) } catch let error as CLIUsageError { return .failure(error) } catch {
            return .failure(CLIUsageError("\(error)"))
        }
    }

    private static func parseThrowing(_ arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else { throw CLIUsageError("No command given.") }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "--help", "-h", "help": return .help
        case "--version", "-V", "version": return .version
        case "convert": return .convert(try parseConvert(rest))
        case "presets": return try parsePresets(rest)
        case "jobs": return try parseJobs(rest)
        default: throw CLIUsageError("Unknown command '\(first)'.")
        }
    }

    // MARK: presets and jobs

    private static func parsePresets(_ arguments: [String]) throws -> CLICommand {
        guard arguments.first == "list" else { throw CLIUsageError("Usage: imageconverter presets list [--json]") }
        return .presetsList(json: try jsonOnly(Array(arguments.dropFirst())))
    }

    private static func parseJobs(_ arguments: [String]) throws -> CLICommand {
        switch arguments.first {
        case "list": return .jobsList(json: try jsonOnly(Array(arguments.dropFirst())))
        case "run":
            var name: String?
            var quiet = false
            var json = false
            for argument in arguments.dropFirst() {
                switch argument {
                case "--quiet": quiet = true
                case "--json": json = true
                default:
                    if argument.hasPrefix("--") { throw CLIUsageError("Unknown option '\(argument)'.") }
                    guard name == nil else { throw CLIUsageError("Give one job name (quote names with spaces).") }
                    name = argument
                }
            }
            guard let name else { throw CLIUsageError("Usage: imageconverter jobs run NAME [--quiet|--json]") }
            return .jobsRun(name: name, quiet: quiet, json: json)
        default: throw CLIUsageError("Usage: imageconverter jobs list|run NAME")
        }
    }

    private static func jsonOnly(_ arguments: [String]) throws -> Bool {
        var json = false
        for argument in arguments {
            guard argument == "--json" else { throw CLIUsageError("Unknown option '\(argument)'.") }
            json = true
        }
        return json
    }

    // MARK: convert

    private static let valueFlags: Set<String> = [
        "--preset", "--pipeline", "--out", "--suffix", "--format", "--quality", "--max-size", "--resize-long",
        "--report"
    ]
    private static let switchFlags: Set<String> = [
        "--same-folder", "--overwrite", "--yes", "--strip-gps", "--strip-all", "--dry-run", "--quiet", "--json"
    ]

    static func parseConvert(_ arguments: [String]) throws -> ConvertOptions {
        var options = ConvertOptions()
        var index = 0
        var onlyInputs = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard !onlyInputs, argument.hasPrefix("--") else {
                options.inputs.append(argument)
                continue
            }
            if argument == "--" { onlyInputs = true; continue }
            var name = argument
            var value: String?
            if let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                value = String(argument[argument.index(after: equals)...])
            }
            if switchFlags.contains(name) {
                guard value == nil else { throw CLIUsageError("'\(name)' takes no value.") }
                apply(switch: name, to: &options)
            } else if valueFlags.contains(name) {
                if value == nil {
                    guard index < arguments.count else { throw CLIUsageError("'\(name)' needs a value.") }
                    value = arguments[index]
                    index += 1
                }
                try apply(value: value ?? "", for: name, to: &options)
            } else {
                throw CLIUsageError("Unknown option '\(name)'.")
            }
        }
        try validate(options)
        return options
    }

    private static func apply(switch name: String, to options: inout ConvertOptions) {
        switch name {
        case "--same-folder": options.sameFolder = true
        case "--overwrite": options.overwrite = true
        case "--yes": options.confirmed = true
        case "--strip-gps": options.stripGPS = true
        case "--strip-all": options.stripAll = true
        case "--dry-run": options.dryRun = true
        case "--quiet": options.quiet = true
        default: options.json = true
        }
    }

    private static func apply(value: String, for name: String, to options: inout ConvertOptions) throws {
        switch name {
        case "--preset": options.preset = value
        case "--pipeline": options.pipelineFile = value
        case "--out": options.outputDirectory = value
        case "--suffix": options.suffix = value
        case "--format": options.format = try format(value)
        case "--quality": options.quality = try quality(value)
        case "--max-size": options.maxSizeBytes = try maxSize(value)
        case "--resize-long": options.resizeLongEdge = try longEdge(value)
        default:
            guard let report = ReportFormat(rawValue: value.lowercased()) else {
                throw CLIUsageError("--report must be csv, json or text.")
            }
            options.report = report
        }
    }

    static func quality(_ value: String) throws -> Double {
        guard let number = Int(value), (0...100).contains(number) else {
            throw CLIUsageError("--quality must be a whole number from 0 to 100.")
        }
        return Double(number) / 100
    }

    static func longEdge(_ value: String) throws -> Int {
        guard let pixels = Int(value), (1...maxResizeEdge).contains(pixels) else {
            throw CLIUsageError("--resize-long must be a whole number of pixels from 1 to \(maxResizeEdge).")
        }
        return pixels
    }

    static func format(_ text: String) throws -> OutputFormat {
        switch text.lowercased() {
        case "jpeg", "jpg": return .jpeg
        case "png": return .png
        case "heic": return .heic
        case "avif": return .avif
        case "tiff", "tif": return .tiff
        case "gif": return .gif
        case "bmp": return .bmp
        case "jpeg2000", "jp2": return .jpeg2000
        default: throw CLIUsageError("Unknown format '\(text)'. Use jpeg, png, heic, avif, tiff, gif, bmp or jpeg2000.")
        }
    }

    /// "500KB", "1.5MB" (decimal, like Finder) or a plain byte count ("200000", "200000B").
    static func maxSize(_ text: String) throws -> Int {
        let upper = text.trimmingCharacters(in: .whitespaces).uppercased()
        let parsed: Int?
        if upper.hasSuffix("KB") {
            parsed = parseSizeBytes(String(upper.dropLast(2)), unit: .kilobytes)
        } else if upper.hasSuffix("MB") {
            parsed = parseSizeBytes(String(upper.dropLast(2)), unit: .megabytes)
        } else {
            parsed = Int(upper.hasSuffix("B") ? String(upper.dropLast()) : upper).flatMap { $0 > 0 ? $0 : nil }
        }
        guard let bytes = parsed else { throw CLIUsageError("--max-size must look like 500KB, 1.5MB or 200000.") }
        return bytes
    }

    private static func validate(_ options: ConvertOptions) throws {
        guard !options.inputs.isEmpty else { throw CLIUsageError("Give at least one file or folder to convert.") }
        if options.preset != nil && options.pipelineFile != nil {
            throw CLIUsageError("Use either --preset or --pipeline, not both.")
        }
        let modes = [options.outputDirectory != nil, options.sameFolder, options.overwrite].filter { $0 }.count
        guard modes == 1 else {
            throw CLIUsageError("Choose exactly one of --out DIR, --same-folder or --overwrite --yes.")
        }
        if options.overwrite && !options.confirmed {
            throw CLIUsageError("--overwrite replaces your originals; add --yes to confirm.")
        }
        if options.suffix != nil && !options.sameFolder { throw CLIUsageError("--suffix only works with --same-folder.") }
        if options.confirmed && !options.overwrite { throw CLIUsageError("--yes only goes with --overwrite.") }
        if options.json, let report = options.report, report != .json {
            throw CLIUsageError("--json prints the JSON report; drop --report or use --report json.")
        }
    }
}
