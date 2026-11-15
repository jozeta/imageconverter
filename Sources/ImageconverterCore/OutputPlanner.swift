import Foundation

/// Where converted files go.
public enum OutputMode: Codable, Equatable, Sendable {
    case newFolder(URL)
    case sameFolder(suffix: String)
    case overwrite

    public var kind: OutputModeKind {
        switch self {
        case .newFolder: return .newFolder
        case .sameFolder: return .sameFolder
        case .overwrite: return .overwrite
        }
    }
}

public enum OutputModeKind: String, Codable, CaseIterable, Sendable {
    case newFolder, sameFolder, overwrite
}

/// True only when the user switches to overwrite mode from another mode.
public func needsOverwriteWarning(from old: OutputModeKind, to new: OutputModeKind) -> Bool {
    new == .overwrite && old != .overwrite
}

public struct PlannedOutput: Equatable, Sendable {
    public let item: InputItem
    public let destination: URL
    public let replacesSource: Bool
    public let trashesSource: Bool

    /// Why a refused plan was refused (the item's failure), when the planner says.
    public var failureReason: String?

    public init(item: InputItem, destination: URL, replacesSource: Bool, trashesSource: Bool,
                failureReason: String? = nil) {
        self.item = item
        self.destination = destination
        self.replacesSource = replacesSource
        self.trashesSource = trashesSource
        self.failureReason = failureReason
    }

    /// A plan the planner refused (a second plan for the same original, or no free name): `FileCommitter`
    /// rejects it.
    public var isRefused: Bool { replacesSource && trashesSource }
}

/// One item to plan: its format (or the source's own extension, for a copy of the original) and name.
public struct OutputTarget: Equatable, Sendable {
    public let item: InputItem
    /// Written without its leading dot; may be empty (a source without an extension, copied).
    public let fileExtension: String
    /// Extensions that count as the same format for overwriting in place (lowercased).
    let acceptedExtensions: [String]
    /// Nil keeps the source's name.
    public let baseName: String?
    /// Folder names (outermost first) under the output folder or the source's folder; ignored when
    /// overwriting. Unsafe names (empty, `.`, `..`, with `/`) are dropped, and at most `SubfolderTemplate.maxDepth`.
    public let subfolder: [String]

    public init(item: InputItem, format: OutputFormat, baseName: String? = nil, subfolder: [String] = []) {
        self.item = item
        fileExtension = format.fileExtensions[0]
        acceptedExtensions = format.fileExtensions
        self.baseName = baseName
        self.subfolder = Self.safe(subfolder)
    }

    /// The source's bytes under its own extension: overwrite mode then leaves the file where it is.
    public static func copyOfOriginal(_ item: InputItem, baseName: String? = nil, subfolder: [String] = []) -> OutputTarget {
        OutputTarget(item: item, fileExtension: item.source.pathExtension, baseName: baseName, subfolder: subfolder)
    }

    private init(item: InputItem, fileExtension: String, baseName: String?, subfolder: [String]) {
        self.item = item
        self.fileExtension = fileExtension
        acceptedExtensions = [fileExtension.lowercased()]
        self.baseName = baseName
        self.subfolder = Self.safe(subfolder)
    }

    private static func safe(_ names: [String]) -> [String] {
        Array(names.filter(SubfolderTemplate.isSafeName).prefix(SubfolderTemplate.maxDepth))
    }
}

public enum OutputPlanner {
    /// Suffix offered by default for same-folder output.
    public static let defaultSuffix = "_new"

    /// Plans one destination per item, in input order. An original is only ever replaced or
    /// trashed in overwrite mode; no other file is replaced, and no two outputs share a path
    /// (compared case-insensitively, as macOS volumes usually are).
    ///
    /// - New folder: every output goes flat into the chosen folder (source subfolders are not
    ///   mirrored), or into the target's own subfolder of it; clashes (per final folder) get `_2`, `_3`, ...
    /// - Same folder: the suffix is appended only when the output would otherwise be the source
    ///   file itself; other clashes get `_2`, `_3`, ...
    /// - Overwrite: the output goes into the source's own folder under its (new) name. When that is the source
    ///   itself (same name and format) it is replaced in place; otherwise the original goes to the Trash after
    ///   the new file is saved. Other items' originals count as taken, so a rename never lands on one (`_2`).
    public static func plan(
        _ items: [InputItem],
        format: OutputFormat,
        mode: OutputMode,
        baseNames: [String]? = nil,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [PlannedOutput] {
        let names: [String?] = baseNames?.count == items.count ? baseNames ?? [] : items.map { _ in nil }
        let targets = zip(items, names).map { OutputTarget(item: $0.0, format: format, baseName: $0.1) }
        return plan(targets, mode: mode, fileExists: fileExists)
    }

    /// Plans one destination per target, in order, with the same rules as `plan(_:format:...)` but a format,
    /// extension and name per item (conditions can change them per image). `reservedSources` are files that
    /// are part of the batch but get no output (skipped by a condition): no plan may target them either.
    /// `fileExists` is asked for every candidate name: a fake that always answers true (tests) makes every name
    /// taken, so a plan that isn't in place never finds a free name; answer true only for the paths meant to exist.
    public static func plan(
        _ targets: [OutputTarget],
        mode: OutputMode,
        reservedSources: [URL] = [],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [PlannedOutput] {
        let isOverwrite = mode == .overwrite
        var claimed = Set<String>()

        func sourceName(_ item: InputItem) -> String { item.source.deletingPathExtension().lastPathComponent }
        // No plan may target another item's source file, whatever `fileExists` says: outside overwrite mode not
        // even its own (with an empty suffix); in overwrite mode only its own, in place. So a rename never lands
        // on an original that is still to be processed. A skipped file is never replaced, in any mode.
        claimed.formUnion(targets.map { key($0.item.source) })
        claimed.formUnion(reservedSources.map(key))

        var plans: [PlannedOutput] = []
        var plannedSources = Set<String>()
        for target in targets {
            let item = target.item
            // Overwrite mode refuses a second plan for a source already planned (the batch deduplicates first;
            // this is the guard): it gets a plan `FileCommitter` rejects ("Invalid output plan") before
            // touching anything, so one original is never replaced or trashed twice.
            if isOverwrite, !plannedSources.insert(FileIdentity.key(item.source)).inserted {
                plans.append(PlannedOutput(item: item, destination: item.source, replacesSource: true,
                                           trashesSource: true))
                continue
            }
            if isOverwrite, isInPlace(target) {
                plans.append(PlannedOutput(item: item, destination: item.source,
                                           replacesSource: true, trashesSource: false))
                continue
            }

            let sourceDir = item.source.deletingLastPathComponent()
            let name = target.baseName ?? sourceName(item)
            let dotExt = target.fileExtension.isEmpty ? "" : ".\(target.fileExtension)"
            let directory: URL
            var suffix = ""
            switch mode {
            case .newFolder(let root):
                directory = within(root, target.subfolder)
            case .sameFolder(let value):
                directory = within(sourceDir, target.subfolder)
                // Only a would-be source overwrite needs telling apart from the original.
                let plain = directory.appendingPathComponent("\(name)\(dotExt)")
                if sameFile(plain, item.source) { suffix = sanitized(value) }
            case .overwrite:
                directory = sourceDir
            }

            // Every name up to `_10000` taken: this item fails, nothing is replaced.
            guard let candidate = (1...maxNameAttempts).lazy.map({ number -> URL in
                let base = number == 1 ? "\(name)\(suffix)" : "\(name)\(suffix)_\(number)"
                return directory.appendingPathComponent("\(base)\(dotExt)")
            }).first(where: { !claimed.contains(key($0)) && !fileExists($0) }) else {
                plans.append(PlannedOutput(item: item, destination: item.source, replacesSource: true,
                                           trashesSource: true, failureReason: noFreeNameReason))
                continue
            }

            claimed.insert(key(candidate))
            plans.append(PlannedOutput(item: item, destination: candidate,
                                       replacesSource: false, trashesSource: isOverwrite))
        }
        return plans
    }

    /// Overwriting `target` replaces its source in place: the source already has the output's extension and the
    /// name is unchanged (as the volume compares names: on a case-insensitive volume `IMG` keeps `img.jpg`).
    private static func isInPlace(_ target: OutputTarget) -> Bool {
        let source = target.item.source
        guard target.acceptedExtensions.contains(source.pathExtension.lowercased()) else { return false }
        guard let name = target.baseName else { return true }
        return sameFile(source.deletingLastPathComponent().appendingPathComponent(name)
            .appendingPathExtension(source.pathExtension), source)
    }

    /// How many names (`a`, `a_2`, … `a_10000`) are tried before an item fails.
    static let maxNameAttempts = 10_000
    public static let noFreeNameReason = "Couldn't find a free name"

    /// `base` with the folder names added; `base` itself if the result would lie outside it. Checked on resolved
    /// paths, one folder at a time: an existing folder that is a symbolic link is followed as a write would be, so a
    /// link to somewhere else can't take the output out of `base`.
    static func within(_ base: URL, _ folders: [String]) -> URL {
        guard !folders.isEmpty else { return base }
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var resolved = URL(fileURLWithPath: root, isDirectory: true)
        for name in folders {
            guard SubfolderTemplate.isSafeName(name) else { return base }
            resolved = resolved.appendingPathComponent(name, isDirectory: true).resolvingSymlinksInPath()
            guard resolved.standardizedFileURL.path.hasPrefix(prefix) else { return base }
        }
        return folders.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        key(lhs) == key(rhs)
    }

    /// Paths as the volume compares them (symlinks resolved, case ignored only where the volume ignores it).
    static func key(_ url: URL) -> String {
        FileIdentity.pathKey(url)
    }

    /// Drops path separators and control characters so a suffix cannot leave the folder.
    private static func sanitized(_ suffix: String) -> String {
        String(suffix.unicodeScalars.filter {
            $0 != "/" && $0 != ":" && !CharacterSet.controlCharacters.contains($0)
        })
    }
}
