import Foundation
import ImageconverterCore

/// Where the tool prints, and which folders it reads presets and jobs from (replaceable in tests).
public struct CLIEnvironment: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    public var presetDirectory: URL
    public var jobDirectory: URL
    public var trash: Trasher

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void,
                presetDirectory: URL = PresetStore.defaultDirectory,
                jobDirectory: URL = TemplateStore<JobSettings>.defaultDirectory(folder: "jobs"),
                trash: @escaping Trasher = systemTrash) {
        self.out = out
        self.err = err
        self.presetDirectory = presetDirectory
        self.jobDirectory = jobDirectory
        self.trash = trash
    }

    /// Results to stdout, progress and problems to stderr.
    public static var standard: CLIEnvironment {
        CLIEnvironment(
            out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    }
}

enum CLIText {
    static let usage = """
    imageconverter \(AppInfo.version): batch image conversion from the command line

    Usage:
      imageconverter convert <files or folders...> [options]
      imageconverter presets list [--json]
      imageconverter jobs list [--json]
      imageconverter jobs run NAME [--quiet|--json]
      imageconverter --version | --help

    Convert options:
      --preset NAME | --pipeline FILE.json   Start from a saved preset, or a pipeline/preset JSON file
      --out DIR | --same-folder [--suffix S] | --overwrite --yes
                                              Where results go (exactly one; --overwrite needs --yes)
      --format jpeg|png|heic|avif|tiff|gif|bmp|jpeg2000
      --quality 0-100                         Quality for lossy formats
      --max-size 500KB                        Largest file size (lowers quality as needed)
      --resize-long PX                        Longest edge in pixels
      --strip-gps | --strip-all               Remove GPS data, or all metadata
      --report csv|json|text                  Print a full report to stdout
      --dry-run                               Show what would be written; change nothing
      --quiet                                 No progress on stderr
      --json                                  Machine-readable JSON report on stdout (implies --quiet)

    Options override the preset or pipeline. Results go to stdout, progress to stderr.
    Exit codes: 0 all done, 1 some files failed, 2 usage error, 3 nothing to do.
    """
}
