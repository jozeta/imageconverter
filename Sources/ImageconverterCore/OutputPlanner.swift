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
    /// trashed in overwrite mode; no other file is replaced, and no two outputs share a path
    /// (compared case-insensitively, as macOS volumes usually are).
    public static func plan(
        _ items: [InputItem],
        format: OutputFormat,
        mode: OutputMode,
        baseNames: [String]? = nil,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [PlannedOutput] {
        let names = baseNames?.count == items.count ? baseNames : nil
        let ext = format.fileExtensions[0]
        let isOverwrite = mode == .overwrite
        var claimed = Set<String>()

        func sourceName(_ item: InputItem) -> String { item.source.deletingPathExtension().lastPathComponent }
        // In place means same name and same extension; a new base name makes it a different file.
        func inPlace(_ index: Int) -> Bool {
            let item = items[index]
            guard isOverwrite, format.fileExtensions.contains(item.source.pathExtension.lowercased()) else { return false }
            return names.map { $0[index].lowercased() == sourceName(item).lowercased() } ?? true
        }
        // Pre-claim in-place targets so no other item can take them, whatever `fileExists` says.
        for index in items.indices where inPlace(index) { claimed.insert(key(items[index].source)) }

        var plans: [PlannedOutput] = []
        for (index, item) in items.enumerated() {
            if inPlace(index) {
                plans.append(PlannedOutput(item: item, destination: item.source,
                                           replacesSource: true, trashesSource: false))
                continue
            }

            let sourceDir = item.source.deletingLastPathComponent()
            let name = names?[index] ?? sourceName(item)
            let directory: URL
            var suffix = ""
            switch mode {
            case .newFolder(let root):
                directory = item.relativeDirectory.isEmpty
                    ? root : root.appendingPathComponent(item.relativeDirectory, isDirectory: true)
            case .sameFolder(let value):
                directory = sourceDir
                suffix = names == nil ? sanitized(value) : ""
            case .overwrite:
                directory = sourceDir
            }

            var number = 1
            var candidate: URL
            repeat {
                let base = number == 1 ? "\(name)\(suffix)" : "\(name)\(suffix)_\(number)"
                candidate = directory.appendingPathComponent("\(base).\(ext)")
                number += 1
            } while claimed.contains(key(candidate)) || fileExists(candidate)

            claimed.insert(key(candidate))
            plans.append(PlannedOutput(item: item, destination: candidate,
                                       replacesSource: false, trashesSource: isOverwrite))
        }
        return plans
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
