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
}

public enum OutputPlanner {
    /// Plans one destination per item, in input order. An original is only ever replaced or
    /// trashed in overwrite mode; no other file is replaced, and no two outputs share a path.
    public static func plan(
        _ items: [InputItem],
        format: OutputFormat,
        mode: OutputMode,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [PlannedOutput] {
        let ext = format.fileExtensions[0]
        var claimed = Set<String>()
        var plans: [PlannedOutput] = []

        for item in items {
            let sourceDir = item.source.deletingLastPathComponent()
            let name = item.source.deletingPathExtension().lastPathComponent
            let isOverwrite = mode == .overwrite

            if isOverwrite, format.fileExtensions.contains(item.source.pathExtension.lowercased()) {
                claimed.insert(item.source.path)
                plans.append(PlannedOutput(item: item, destination: item.source,
                                           replacesSource: true, trashesSource: false))
                continue
            }

            let directory: URL
            var suffix = ""
            switch mode {
            case .newFolder(let root):
                directory = item.relativeDirectory.isEmpty
                    ? root : root.appendingPathComponent(item.relativeDirectory, isDirectory: true)
            case .sameFolder(let value):
                directory = sourceDir
                suffix = value
            case .overwrite:
                directory = sourceDir
            }

            var number = 1
            var candidate: URL
            repeat {
                let base = number == 1 ? "\(name)\(suffix)" : "\(name)\(suffix)_\(number)"
                candidate = directory.appendingPathComponent("\(base).\(ext)")
                number += 1
            } while isTaken(candidate, item: item, claimed: claimed, allowOwnSource: isOverwrite, fileExists: fileExists)

            claimed.insert(candidate.path)
            plans.append(PlannedOutput(item: item, destination: candidate,
                                       replacesSource: false, trashesSource: isOverwrite))
        }
        return plans
    }

    private static func isTaken(_ candidate: URL, item: InputItem, claimed: Set<String>,
                                allowOwnSource: Bool, fileExists: (URL) -> Bool) -> Bool {
        if claimed.contains(candidate.path) { return true }
        if allowOwnSource && candidate.path == item.source.path { return false }
        return fileExists(candidate)
    }
}
