import Foundation

/// Reopening an interrupted batch's files in the sandbox: the folder, loose-file and output bookmarks the journal
/// keeps (made while the run had access) and resolving them again on resume.
extension RunJournal {
    /// Bookmarks of the `sources` whose folder no folder in `bookmarked` contains (one coverage check per folder),
    /// in order, one per path, at most `maxFileBookmarks`.
    static func looseFileBookmarks(_ sources: [URL], bookmarked: [URL],
                                   bookmarker: (URL) -> Data?) -> [FolderBookmark] {
        var covered: [String: Bool] = [:]
        var seen = Set<String>()
        var files: [FolderBookmark] = []
        for source in sources where files.count < maxFileBookmarks {
            let folder = source.deletingLastPathComponent()
            let key = folder.standardizedFileURL.path
            let isCovered = covered[key] ?? bookmarked.contains { AccessNeeds.isCovered(folder, by: $0) }
            covered[key] = isCovered
            guard !isCovered, seen.insert(source.path).inserted, let data = bookmarker(source) else { continue }
            files.append(FolderBookmark(path: source.path, bookmark: data))
        }
        return files
    }

    /// The loose files whose bookmarks resolve (start access on these exact URLs; in the real sandbox only
    /// security-scoped ones count). One that doesn't resolve is left out: resuming asks for its folder.
    public func regainFileAccess(resolver: (Data) -> FolderAccess.Resolved? = FolderAccess.resolveFile,
                                 enforced: Bool = Sandbox.isEnforced) -> [URL] {
        (fileBookmarks ?? []).compactMap { file in
            guard let resolved = resolver(file.bookmark), resolved.isSecurityScoped || !enforced else { return nil }
            return resolved.url
        }
    }

    /// What resuming can open again: the folders whose bookmarks resolve (start access on these exact URLs), and
    /// the folders that can't be found or opened any more (by their recorded path). In the real sandbox
    /// (`enforced`) a bookmark that resolves only as a plain one gives no access, so it counts as unavailable.
    public func regainAccess(resolver: (Data) -> FolderAccess.Resolved? = FolderAccess.resolve,
                             enforced: Bool = Sandbox.isEnforced) -> (access: [URL], unavailable: [URL]) {
        var access: [URL] = []
        var unavailable: [URL] = []
        func regain(_ data: Data, folder: URL) {
            if let resolved = resolver(data), resolved.isSecurityScoped || !enforced {
                access.append(resolved.url)
            } else {
                unavailable.append(folder)
            }
        }
        for folder in folderBookmarks ?? [] {
            regain(folder.bookmark, folder: URL(fileURLWithPath: folder.path, isDirectory: true))
        }
        if let outputBookmark, case .newFolder(let folder) = outputMode { regain(outputBookmark, folder: folder) }
        return (access, unavailable)
    }
}
