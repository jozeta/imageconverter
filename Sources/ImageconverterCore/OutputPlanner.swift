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

    public init(item: InputItem, destination: URL, replacesSource: Bool, trashesSource: Bool) {
        self.item = item
        self.destination = destination
        self.replacesSource = replacesSource
        self.trashesSource = trashesSource
    }

    /// A plan the planner refused (a second plan for the same original): `FileCommitter` rejects it.
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

    public init(item: InputItem, format: OutputFormat, baseName: String? = nil) {
        self.item = item
        fileExtension = format.fileExtensions[0]
        acceptedExtensions = format.fileExtensions
        self.baseName = baseName
    }

    /// The source's bytes under its own extension: overwrite mode then leaves the file where it is.
    public static func copyOfOriginal(_ item: InputItem, baseName: String? = nil) -> OutputTarget {
        OutputTarget(item: item, fileExtension: item.source.pathExtension, baseName: baseName)
    }

    private init(item: InputItem, fileExtension: String, baseName: String?) {
        self.item = item
        self.fileExtension = fileExtension
        acceptedExtensions = [fileExtension.lowercased()]
        self.baseName = baseName
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
    ///   mirrored); clashes get `_2`, `_3`, ...
    /// - Same folder: the suffix is appended only when the output would otherwise be the source
    ///   file itself; other clashes get `_2`, `_3`, ...
    /// - Overwrite: `baseNames` is ignored (renaming is disabled), so the name stays the source's.
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
    public static func plan(
        _ targets: [OutputTarget],
        mode: OutputMode,
        reservedSources: [URL] = [],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [PlannedOutput] {
        let isOverwrite = mode == .overwrite
        var claimed = Set<String>()

        func sourceName(_ item: InputItem) -> String { item.source.deletingPathExtension().lastPathComponent }
        // In place means overwrite mode and the source already has the output's extension
        // (names are ignored when overwriting).
        func inPlace(_ target: OutputTarget) -> Bool {
            isOverwrite && target.acceptedExtensions.contains(target.item.source.pathExtension.lowercased())
        }
        // Pre-claim in-place targets so no other item can take them, whatever `fileExists` says. Outside
        // overwrite mode no plan may ever target a source file, even with an empty suffix. A skipped file is
        // never replaced, in any mode.
        claimed.formUnion(targets.filter { !isOverwrite || inPlace($0) }.map { key($0.item.source) })
        claimed.formUnion(reservedSources.map(key))

        var plans: [PlannedOutput] = []
        var plannedSources = Set<String>()
        for target in targets {
            let item = target.item
            // Overwrite mode refuses a second plan for a source already planned (the batch deduplicates first;
            // this is the guard): it gets a plan `FileCommitter` rejects ("Invalid output plan") before
            // touching anything, so one original is never replaced or trashed twice.
            if isOverwrite, !plannedSources.insert(key(item.source)).inserted {
                plans.append(PlannedOutput(item: item, destination: item.source, replacesSource: true,
                                           trashesSource: true))
                continue
            }
            if inPlace(target) {
                plans.append(PlannedOutput(item: item, destination: item.source,
                                           replacesSource: true, trashesSource: false))
                continue
            }

            let sourceDir = item.source.deletingLastPathComponent()
            // Renaming is disabled when overwriting, so a leftover template can't change the plan.
            let name = (isOverwrite ? nil : target.baseName) ?? sourceName(item)
            let dotExt = target.fileExtension.isEmpty ? "" : ".\(target.fileExtension)"
            let directory: URL
            var suffix = ""
            switch mode {
            case .newFolder(let root):
                directory = root
            case .sameFolder(let value):
                directory = sourceDir
                // Only a would-be source overwrite needs telling apart from the original.
                let plain = directory.appendingPathComponent("\(name)\(dotExt)")
                if sameFile(plain, item.source) { suffix = sanitized(value) }
            case .overwrite:
                directory = sourceDir
            }

            var number = 1
            var candidate: URL
            repeat {
                let base = number == 1 ? "\(name)\(suffix)" : "\(name)\(suffix)_\(number)"
                candidate = directory.appendingPathComponent("\(base)\(dotExt)")
                number += 1
            } while claimed.contains(key(candidate)) || fileExists(candidate)

            claimed.insert(key(candidate))
            plans.append(PlannedOutput(item: item, destination: candidate,
                                       replacesSource: false, trashesSource: isOverwrite))
        }
        return plans
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.deletingLastPathComponent().standardizedFileURL.path
            == rhs.deletingLastPathComponent().standardizedFileURL.path
            && lhs.lastPathComponent.lowercased() == rhs.lastPathComponent.lowercased()
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    /// Drops path separators and control characters so a suffix cannot leave the folder.
    private static func sanitized(_ suffix: String) -> String {
        String(suffix.unicodeScalars.filter {
            $0 != "/" && $0 != ":" && !CharacterSet.controlCharacters.contains($0)
        })
    }
}
