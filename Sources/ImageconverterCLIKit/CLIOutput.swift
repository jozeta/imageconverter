import Foundation
import ImageconverterCore

/// Lets the signal handler (or a test) stop the running batch: the batch task is cancelled, its in-flight files
/// finish their atomic commit or are dropped, and the command then prints the partial report.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelWork: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock()
        cancelled = true
        let action = cancelWork
        lock.unlock()
        action?()
    }

    /// Runs `body` in a task that `cancel()` cancels (at once if it was cancelled already).
    func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let work = Task { await body() }
        if attach({ work.cancel() }) { work.cancel() }
        return await work.value
    }

    /// Stores the cancel action; true when cancellation already happened.
    private func attach(_ action: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cancelWork = action
        return cancelled
    }
}

/// Where the tool prints, and which folders it reads presets and jobs from (replaceable in tests).
public struct CLIEnvironment: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    public var presetDirectory: URL
    public var jobDirectory: URL
    public var trash: Trasher
    public var cancel: CancelToken
    /// Pauses and resumes a `convert` run (nil in the tool itself; tests use it as a deterministic gate).
    public var control: BatchControl?

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void,
                presetDirectory: URL = PresetStore.defaultDirectory,
                jobDirectory: URL = TemplateStore<JobSettings>.defaultDirectory(folder: "jobs"),
                trash: @escaping Trasher = systemTrash, cancel: CancelToken = CancelToken()) {
        self.out = out
        self.err = err
        self.presetDirectory = presetDirectory
        self.jobDirectory = jobDirectory
        self.trash = trash
        self.cancel = cancel
    }

    /// Results to stdout, progress and problems to stderr; presets and jobs from the app's data folder (its
    /// container when the sandboxed app has one, see `CLIDataDirectory`).
    public static func standard(cancel: CancelToken = CancelToken()) -> CLIEnvironment {
        CLIEnvironment(
            out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }, cancel: cancel)
            .with(dataDirectory: CLIDataDirectory.resolve(home: CLIDataDirectory.realHome))
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

    Global options:
      --data-dir DIR                          Read presets and jobs from DIR (default: the app's container,
                                              else ~/Library/Application Support/imageconverter)

    Convert options:
      --preset NAME | --pipeline FILE.json   Start from a saved preset, or a pipeline/preset JSON file
      --out DIR | --same-folder [--suffix S] | --overwrite --yes
                                              Where results go (exactly one; --overwrite needs --yes)
      --format jpeg|png|heic|avif|tiff|gif|bmp|jpeg2000
      --quality 0-100                         Quality for lossy formats
      --max-size 500KB                        Largest file size (lowers quality as needed)
      --resize-long PX                        Longest edge in pixels
      --strip-gps | --strip-all               Remove GPS data, or all metadata (ignores the preset's keep list)
      --report csv|json|text                  Print a full report to stdout
      --dry-run                               Show what would be written; change nothing
      --quiet                                 No progress on stderr (Ctrl-C stops cleanly, exit 130)
      --json                                  Machine-readable JSON report on stdout (implies --quiet)

    Options override the preset or pipeline. Results go to stdout, progress to stderr.
    Files starting with '-' need '--' before them. Exit codes: 0 all done, 1 some files failed or missing,
    2 usage error, 3 nothing to do, 130 interrupted.
    """
}
