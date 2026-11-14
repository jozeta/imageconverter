import Foundation

/// Where the tool finds the app's presets and jobs. The sandboxed app keeps them in its container, so the tool
/// looks there first; an unsandboxed app (`swift run`) uses the plain Application Support folder. `--data-dir`
/// overrides both.
public enum CLIDataDirectory {
    /// The app's bundle identifier, which names its container (kept equal to `BUNDLE_ID` in `scripts/release.sh`).
    public static let bundleIdentifier = "io.github.jozeta.imageconverter"

    /// `<home>/Library/Containers/<bundle id>/Data/Library/Application Support/imageconverter`.
    public static func container(home: URL) -> URL {
        home.appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support/imageconverter", isDirectory: true)
    }

    /// `<home>/Library/Application Support/imageconverter`.
    public static func plain(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/imageconverter", isDirectory: true)
    }

    /// `override` (a `--data-dir` value, `~` expanded) when given; else the container's folder when it exists,
    /// else the plain one.
    public static func resolve(home: URL, override: String? = nil,
                               directoryExists: (URL) -> Bool = CLIDataDirectory.isDirectory) -> URL {
        if let override {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        let container = container(home: home)
        return directoryExists(container) ? container : plain(home: home)
    }

    /// The user's real home folder (not a container's, should the tool ever run inside one).
    public static var realHome: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Takes `--data-dir DIR` / `--data-dir=DIR` out of `arguments` (only before a `--` terminator). Throws a usage
    /// error when it has no value or is given twice.
    static func extract(_ arguments: [String]) throws -> (arguments: [String], dataDirectory: String?) {
        var rest: [String] = []
        var value: String?
        var index = 0
        var terminated = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if terminated || (argument != "--data-dir" && !argument.hasPrefix("--data-dir=")) {
                if argument == "--" { terminated = true }
                rest.append(argument)
                continue
            }
            guard value == nil else { throw CLIUsageError("'--data-dir' was given more than once.") }
            if argument == "--data-dir" {
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw CLIUsageError("'--data-dir' needs a value.")
                }
                value = arguments[index]
                index += 1
            } else {
                value = String(argument.dropFirst("--data-dir=".count))
            }
            if value?.isEmpty ?? true { throw CLIUsageError("'--data-dir' needs a value.") }
        }
        return (rest, value)
    }
}

extension CLIEnvironment {
    /// The same environment reading presets and jobs from `directory` (`presets/` and `jobs/` inside it).
    public func with(dataDirectory directory: URL) -> CLIEnvironment {
        var copy = self
        copy.presetDirectory = directory.appendingPathComponent("presets", isDirectory: true)
        copy.jobDirectory = directory.appendingPathComponent("jobs", isDirectory: true)
        return copy
    }
}
