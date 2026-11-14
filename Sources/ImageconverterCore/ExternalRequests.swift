import Foundation

/// Why a request from AppleScript, a Finder service or a link can't be carried out, in words for the user.
public enum ExternalRequestError: Error, Equatable, Sendable {
    case noFiles
    case tooManyFiles(max: Int)
    case unreadable(path: String)
    case notAFolder(path: String)
    case notAFile(description: String)
    case unknownPreset(name: String)
    case unknownJob(name: String)
    case noOutputFolder
    case nothingToRun
    case busy
    case cancelled
    /// A script can't answer "Discard the interrupted batch?", so its run is refused instead.
    case interruptedBatchWaiting
    /// Sandbox: the user didn't allow a folder the run needs.
    case noFolderAccess

    public var message: String {
        switch self {
        case .noFiles: return "No files were given."
        case .tooManyFiles(let max): return "At most \(max) files can be given at once."
        case .unreadable(let path): return "\(path) doesn't exist or can't be read."
        case .notAFile(let description):
            return "\(description) isn't a file. Give an alias, a POSIX file or a full POSIX path such as \"/Users/me/a.jpg\"."
        case .notAFolder(let path): return "\(path) isn't a folder you can write to."
        case .unknownPreset(let name): return "There is no preset named \"\(name)\"."
        case .unknownJob(let name): return "There is no job named \"\(name)\"."
        case .noOutputFolder: return "Choose an output folder in imageconverter first, or give one with \"to folder\"."
        case .nothingToRun: return "Add images to imageconverter first."
        case .busy: return "imageconverter is already converting. Try again when the run has finished."
        case .cancelled: return "The conversion was cancelled."
        case .interruptedBatchWaiting:
            return "An interrupted batch is waiting; resume or discard it first."
        case .noFolderAccess:
            return "imageconverter wasn't allowed to use a folder the conversion needs, so nothing was converted."
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
    /// What an external request that starts a run does about a kept interrupted batch, which the run would replace.
    public enum InterruptedRunDecision: Equatable, Sendable {
        case proceed
        /// Ask "Discard the interrupted batch?" like Run (a Finder service).
        case ask
        /// Refuse with `ExternalRequestError.interruptedBatchWaiting` (a script can't answer a question).
        case refuse
    }

    public static func interruptedRunDecision(hasInterruptedRun: Bool, interactive: Bool) -> InterruptedRunDecision {
        guard hasInterruptedRun else { return .proceed }
        return interactive ? .ask : .refuse
    }

    /// Asks `questions` in order and stops at the first "no" (`ExternalRequestError.cancelled`); only when every
    /// one was confirmed does `commit` run (e.g. discarding the interrupted batch), so a later Cancel never loses
    /// anything an earlier answer agreed to give up.
    @MainActor
    public static func confirmAll(_ questions: [@MainActor () async -> Bool], commit: @MainActor () -> Void)
        async throws {
        for question in questions where !(await question()) { throw ExternalRequestError.cancelled }
        commit()
    }

    public static let maxFiles = 10_000

    /// The files in an AppleScript parameter: one or a list of aliases, `POSIX file` values (both arrive as
    /// URLs) or full POSIX paths as text. Anything else, or a relative path, throws a message that says so.
    public static func fileURLs(fromScriptValue value: Any?) throws -> [URL] {
        func one(_ element: Any) throws -> URL {
            if let url = element as? URL { return url }
            if let path = element as? String {
                guard path.hasPrefix("/") else { throw ExternalRequestError.notAFile(description: path) }
                return URL(fileURLWithPath: path)
            }
            throw ExternalRequestError.notAFile(description: String(describing: type(of: element)))
        }
        switch value {
        case nil: throw ExternalRequestError.noFiles
        case let list as [Any]: return try list.map(one)
        case let element?: return [try one(element)]
        }
    }

    /// Up to `limit` paths, one per line, then "…and N more": what a confirmation lists.
    public static func fileList(_ urls: [URL], limit: Int = 5) -> String {
        let shown = urls.prefix(limit).map(\.path).joined(separator: "\n")
        return urls.count > limit ? shown + "\n…and \(urls.count - limit) more" : shown
    }

    /// The body of a run confirmation: how many images, which preset (or pipeline), where they go, and which files.
    public static func runSummary(files: [URL], pipelineName: String, mode: OutputMode) -> String {
        let count = files.count
        return "Converts \(count) \(count == 1 ? "image" : "images") with \(pipelineName) and "
            + describe(mode) + ".\n\n" + fileList(files)
    }

    /// Where a run writes, for the confirmation that names what will happen.
    public static func describe(_ mode: OutputMode) -> String {
        switch mode {
        case .newFolder(let folder): return "writes the converted images to the folder \(folder.path)"
        case .sameFolder(let suffix):
            return "writes the converted images next to the originals, with \"\(suffix)\" added to their names"
        case .overwrite:
            return "replaces the original images (when the name or format changes, the original is moved to the Trash "
                + "after the new file is saved)"
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
/// app's Info.plist, so there is a fixed number of slots; each pinned preset keeps its own slot number
/// (`Preset.serviceSlot`) until it is unpinned, so renaming or (un)pinning others never moves it.
public enum ServicePins {
    public static let maxPinned = 5
    public static let slots = 1...maxPinned

    /// The user presets with a slot, in slot order; for a duplicated slot (hand-edited files) the first by name.
    public static func pinned(_ presets: [Preset]) -> [Preset] {
        slots.compactMap { preset(forSlot: $0, in: presets) }
    }

    /// The user preset in `slot`, or nil when the slot is empty.
    public static func preset(forSlot slot: Int, in presets: [Preset]) -> Preset? {
        presets.filter { !$0.isBuiltIn && $0.serviceSlot == slot }
            .min { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The lowest slot no user preset uses, or nil when all are taken.
    public static func freeSlot(in presets: [Preset]) -> Int? {
        let used = Set(presets.filter { !$0.isBuiltIn }.compactMap(\.serviceSlot))
        return slots.first { !used.contains($0) }
    }

    /// Pinning `id` is allowed while a slot is free (or it already has one); unpinning always is.
    public static func canPin(_ id: UUID, in presets: [Preset]) -> Bool {
        presets.contains { $0.id == id && $0.pinnedForServices } || freeSlot(in: presets) != nil
    }
}
