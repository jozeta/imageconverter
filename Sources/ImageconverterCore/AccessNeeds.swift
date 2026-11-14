import Foundation

/// Whether the app runs inside the App Sandbox, where it can only touch files and folders the user chose (or
/// that it kept a bookmark for). DEBUG builds can pretend (`simulated`, set by `-debugSimulateSandbox`), so the
/// access prompts can be seen in an unsandboxed `swift run`.
public enum Sandbox {
    public static var isActive: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil || simulated
    }

    /// Set once at launch, before any run (DEBUG only; always false in release builds).
    nonisolated(unsafe) public static var simulated = false
}

/// Which folders a run needs access to that the app hasn't been given yet. Pure: the caller says which folders
/// are covered (remembered grants, folders dropped this session, the output folder's bookmark).
public enum AccessNeeds {
    /// Why a folder is needed, for the question the app asks.
    public enum Purpose: Equatable, Sendable {
        /// Same-folder mode writes next to each original.
        case saveNextToOriginals
        /// Overwrite mode replaces each original (and may move it to the Trash).
        case replaceOriginals
        /// New-folder mode writes into the output folder.
        case saveToOutputFolder
        /// New-folder mode: a source that can't be read now (its folder isn't covered either).
        case readOriginals
    }

    public struct Need: Equatable, Sendable {
        public var folder: URL
        public var purpose: Purpose

        public init(folder: URL, purpose: Purpose) {
            self.folder = folder
            self.purpose = purpose
        }
    }

    /// The folders `mode` writes into for `sources` that no folder in `covered` contains: in same-folder and
    /// overwrite mode the sources' parent folders, in new-folder mode only the output folder. Sorted by path,
    /// one entry per folder (symlinks resolved, case as the volume compares it), and a folder inside another
    /// needed folder is left out (allowing the outer one covers it).
    public static func foldersNeedingAccess(sources: [URL], mode: OutputMode, covered: [URL],
                                            caseSensitive: Bool? = nil) -> [URL] {
        needs(sources: sources, mode: mode, covered: covered, caseSensitive: caseSensitive).map(\.folder)
    }

    /// `foldersNeedingAccess` with the reason for each folder. In new-folder mode, sources for which
    /// `isReadable` is false add their parent folders too (`.readOriginals`), unless covered.
    public static func needs(sources: [URL], mode: OutputMode, covered: [URL],
                             isReadable: (URL) -> Bool = { _ in true }, caseSensitive: Bool? = nil) -> [Need] {
        let roots = covered.map { Key($0, caseSensitive: caseSensitive) }
        var candidates: [(key: Key, need: Need)] = []
        var seen = Set<String>()
        func consider(_ folder: URL, _ purpose: Purpose) {
            // Thousands of sources share a few folders: key each spelling once.
            guard seen.insert(folder.standardizedFileURL.path).inserted else { return }
            let key = Key(folder, caseSensitive: caseSensitive)
            guard !roots.contains(where: { $0.contains(key) }) else { return }
            candidates.append((key, Need(folder: folder.standardizedFileURL, purpose: purpose)))
        }
        switch mode {
        case .newFolder(let output):
            consider(output, .saveToOutputFolder)
            for source in sources where !isReadable(source) {
                consider(source.deletingLastPathComponent(), .readOriginals)
            }
        case .sameFolder:
            for source in sources { consider(source.deletingLastPathComponent(), .saveNextToOriginals) }
        case .overwrite:
            for source in sources { consider(source.deletingLastPathComponent(), .replaceOriginals) }
        }
        return collapse(candidates)
    }

    /// The outermost folders among `folders`: one per folder, a folder inside another left out, sorted by path.
    /// What the run journal keeps bookmarks for.
    public static func roots(of folders: [URL], caseSensitive: Bool? = nil) -> [URL] {
        var seen = Set<String>()
        let unique = folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return collapse(unique.map { (Key($0, caseSensitive: caseSensitive), Need(folder: $0.standardizedFileURL,
                                                                            purpose: .readOriginals)) })
            .map(\.folder)
    }

    /// True when `folder` is `root` or inside it (component-wise, symlinks resolved).
    public static func isCovered(_ folder: URL, by root: URL, caseSensitive: Bool? = nil) -> Bool {
        Key(root, caseSensitive: caseSensitive).contains(Key(folder, caseSensitive: caseSensitive))
    }

    /// The indices of the `roots` that contain at least one of `folders` (each path keyed once).
    public static func roots(_ roots: [URL], covering folders: [URL], caseSensitive: Bool? = nil) -> Set<Int> {
        var seen = Set<String>()
        let keys = folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .map { Key($0, caseSensitive: caseSensitive) }
        var result = Set<Int>()
        for (index, root) in roots.enumerated() {
            let rootKey = Key(root, caseSensitive: caseSensitive)
            if keys.contains(where: rootKey.contains) { result.insert(index) }
        }
        return result
    }

    /// Sorted by key so an outer folder comes before the folders inside it; duplicates and nested ones dropped.
    /// The first purpose seen for a folder wins (the output folder before the sources' folders).
    private static func collapse(_ candidates: [(key: Key, need: Need)]) -> [Need] {
        var first: [Key: Need] = [:]
        for candidate in candidates where first[candidate.key] == nil { first[candidate.key] = candidate.need }
        // In sorted order the folders inside a folder follow it directly, so only the last kept one can contain
        // the next key.
        var kept: [Key] = []
        for key in first.keys.sorted() where !(kept.last?.contains(key) ?? false) {
            kept.append(key)
        }
        return kept.compactMap { first[$0] }.sorted { $0.folder.path < $1.folder.path }
    }

    /// A folder as path components, compared the way its volume compares names (`FileIdentity.pathKey`).
    private struct Key: Hashable, Comparable {
        let components: [String]

        init(_ url: URL, caseSensitive: Bool?) {
            let path = FileIdentity.pathKey(url, caseSensitive: caseSensitive)
            components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }

        func contains(_ other: Key) -> Bool {
            other.components.count >= components.count && Array(other.components.prefix(components.count)) == components
        }

        static func < (lhs: Key, rhs: Key) -> Bool {
            lhs.components.lexicographicallyPrecedes(rhs.components)
        }
    }
}
