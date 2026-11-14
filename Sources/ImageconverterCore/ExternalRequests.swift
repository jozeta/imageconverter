import Foundation

/// Why a request from AppleScript, a Finder service or a link can't be carried out, in words for the user.
public enum ExternalRequestError: Error, Equatable, Sendable {
    case noFiles
    case tooManyFiles(max: Int)
    case unreadable(path: String)
    case notAFolder(path: String)
    case unknownPreset(name: String)
    case unknownJob(name: String)
    case noOutputFolder
    case nothingToRun
    case busy
    case cancelled

    public var message: String {
        switch self {
        case .noFiles: return "No files were given."
        case .tooManyFiles(let max): return "At most \(max) files can be given at once."
        case .unreadable(let path): return "\(path) doesn't exist or can't be read."
        case .notAFolder(let path): return "\(path) isn't a folder you can write to."
        case .unknownPreset(let name): return "There is no preset named \"\(name)\"."
        case .unknownJob(let name): return "There is no job named \"\(name)\"."
        case .noOutputFolder: return "Choose an output folder in imageconverter first, or give one with \"to folder\"."
        case .nothingToRun: return "Add images to imageconverter first."
        case .busy: return "imageconverter is already converting. Try again when the run has finished."
        case .cancelled: return "The conversion was cancelled."
        }
    }
}

/// A checked `convert` request: what to convert, with which preset, and where the files go.
public struct ConvertPlan: Equatable, Sendable {
    public var files: [URL]
    public var preset: Preset
    public var mode: OutputMode

    /// Overwrite mode replaces originals, so it is always confirmed in the app first, whoever asked.
    public var needsOverwriteConfirmation: Bool { mode.kind == .overwrite }
}

/// The checks shared by the AppleScript commands and the Finder services. Their input comes from other
/// processes, so every file is checked before anything is read, and names are matched like the app does.
public enum ExternalRequests {
    public static let maxFiles = 10_000

    /// The files in an AppleScript parameter: one file or a list of files (aliases and `file` values arrive as
    /// URLs). Nil when anything else is in it, so a typo'd parameter is an error, not an empty list.
    public static func fileURLs(fromScriptValue value: Any?) -> [URL]? {
        switch value {
        case let url as URL: return [url]
        case let list as [Any]:
            var urls: [URL] = []
            for element in list {
                guard let url = element as? URL else { return nil }
                urls.append(url)
            }
            return urls
        default: return nil
        }
    }

    /// Where a run writes, for the confirmation that names what will happen.
    public static func describe(_ mode: OutputMode) -> String {
        switch mode {
        case .newFolder(let folder): return "writes the converted images to the folder \(folder.path)"
        case .sameFolder(let suffix):
            return "writes the converted images next to the originals, with \"\(suffix)\" added to their names"
        case .overwrite:
            return "replaces the original images (originals whose name or format changes are moved to the Trash)"
        }
    }

    /// File URLs that exist and are readable, standardised and without duplicates, in the given order.
    public static func validatedFiles(_ urls: [URL],
                                      isReadable: (URL) -> Bool = URLAction.isReadableItem) throws -> [URL] {
        guard !urls.isEmpty else { throw ExternalRequestError.noFiles }
        guard urls.count <= maxFiles else { throw ExternalRequestError.tooManyFiles(max: maxFiles) }
        var result: [URL] = []
        var seen = Set<URL>()
        for url in urls {
            guard url.isFileURL else { throw ExternalRequestError.unreadable(path: url.absoluteString) }
            let file = url.standardizedFileURL
            guard isReadable(file) else { throw ExternalRequestError.unreadable(path: file.path) }
            if seen.insert(file).inserted { result.append(file) }
        }
        return result
    }

    /// The preset (built-in or the user's) whose name matches ignoring case and extra spaces.
    public static func preset(named name: String, in presets: [Preset]) throws -> Preset {
        let wanted = StoredFile.fold(name)
        guard !wanted.isEmpty, let preset = presets.first(where: { StoredFile.fold($0.name) == wanted }) else {
            throw ExternalRequestError.unknownPreset(name: name)
        }
        return preset
    }

    /// The job whose name matches ignoring case, like `imageconverter jobs run`.
    public static func job(named name: String, in jobs: [Job]) throws -> Job {
        let wanted = StoredFile.fold(name)
        guard !wanted.isEmpty, let job = jobs.first(where: { StoredFile.fold($0.name) == wanted }) else {
            throw ExternalRequestError.unknownJob(name: name)
        }
        return job
    }

    public static func validatedFolder(_ url: URL, isDirectory: (URL) -> Bool = isWritableDirectory) throws -> URL {
        let folder = url.standardizedFileURL
        guard url.isFileURL, isDirectory(folder) else {
            throw ExternalRequestError.notAFolder(path: url.isFileURL ? folder.path : url.absoluteString)
        }
        return folder
    }

    public static func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// `convert {files} using preset "Name" [to folder f]`: with a folder the files go there (a new folder
    /// output); without one they follow the app's output setting, which is nil when no folder was chosen yet.
    public static func convertPlan(files: [URL], presetName: String, folder: URL?, presets: [Preset],
                                   globalMode: OutputMode?,
                                   isReadable: (URL) -> Bool = URLAction.isReadableItem,
                                   isDirectory: (URL) -> Bool = isWritableDirectory) throws -> ConvertPlan {
        let checked = try validatedFiles(files, isReadable: isReadable)
        let preset = try preset(named: presetName, in: presets)
        let mode: OutputMode
        if let folder {
            mode = .newFolder(try validatedFolder(folder, isDirectory: isDirectory))
        } else {
            guard let globalMode else { throw ExternalRequestError.noOutputFolder }
            mode = globalMode
        }
        return ConvertPlan(files: checked, preset: preset, mode: mode)
    }
}

/// The user presets shown as Finder services ("Show in Finder Quick Actions"). Services are declared in the
/// app's Info.plist, so there is a fixed number of slots; slot n runs the n-th pinned preset by name.
public enum ServicePins {
    public static let maxPinned = 5

    /// The pinned user presets sorted by name, at most `maxPinned` (a hand-edited folder could pin more).
    public static func pinned(_ presets: [Preset]) -> [Preset] {
        Array(presets.filter { $0.pinnedForServices && !$0.isBuiltIn }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(maxPinned))
    }

    /// Slot 1...maxPinned; nil when the slot is empty.
    public static func preset(forSlot slot: Int, in presets: [Preset]) -> Preset? {
        let list = pinned(presets)
        guard slot >= 1, slot <= list.count else { return nil }
        return list[slot - 1]
    }

    /// Pinning `id` is allowed while fewer than `maxPinned` other presets are pinned; unpinning always is.
    public static func canPin(_ id: UUID, in presets: [Preset]) -> Bool {
        presets.filter { $0.pinnedForServices && !$0.isBuiltIn && $0.id != id }.count < maxPinned
    }
}
