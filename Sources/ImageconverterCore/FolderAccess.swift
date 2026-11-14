import Foundation

/// Folder access that survives a relaunch: app-scoped security-scoped bookmarks (what a sandboxed app needs to
/// reopen a folder the user picked once), resolved with stale detection, and access started only around the
/// work that needs it. Without the sandbox the plain URL works, so every step falls back to it.
public enum FolderAccess {
    /// True inside the App Sandbox (`Sandbox.isActive`); the plain-URL fallbacks only apply outside it.
    public static var isSandboxed: Bool { Sandbox.isActive }

    /// A security-scoped bookmark of `url` (read-write, app scope), or a plain bookmark when that can't be made
    /// (outside the sandbox it may not be; a plain one still follows a moved folder). Nil when neither works.
    public static func bookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The bookmark worth keeping in the current process: inside the real sandbox only a security-scoped one (a
    /// plain bookmark resolves there but gives no access); outside it `bookmark(for:)`, plain as a fallback.
    public static func usableBookmark(for url: URL) -> Data? {
        guard Sandbox.isEnforced else { return bookmark(for: url) }
        return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public struct Resolved: Equatable, Sendable {
        public var url: URL
        /// A new bookmark when the stored one was stale (the folder moved or the volume changed); store it.
        public var refreshed: Data?
        /// True when the bookmark resolved as security-scoped (only those can give sandbox access).
        public var isSecurityScoped: Bool

        public init(url: URL, refreshed: Data? = nil, isSecurityScoped: Bool = true) {
            self.url = url
            self.refreshed = refreshed
            self.isSecurityScoped = isSecurityScoped
        }
    }

    /// Bookmark data comes from untrusted files (presets, templates, jobs, the journal): never mount a volume or
    /// show UI to resolve it (a bookmark naming an `smb://` server must not make the system connect to it), and
    /// ignore anything larger than a real bookmark.
    static let resolveOptions: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
    public static let maxBookmarkSize = 65_536

    /// The URL `data` points to, security-scoped when possible; nil for oversized or unresolvable data.
    private static func resolveURL(_ data: Data, stale: inout Bool) -> (URL, scoped: Bool)? {
        guard !data.isEmpty, data.count <= maxBookmarkSize else { return nil }
        if let url = try? URL(resolvingBookmarkData: data, options: resolveOptions.union(.withSecurityScope),
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, true)
        }
        if let url = try? URL(resolvingBookmarkData: data, options: resolveOptions, relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return (url, false)
        }
        return nil
    }

    /// The folder `data` points to now, or nil when it can't be found (deleted, its volume gone or not mounted,
    /// not a folder).
    public static func resolve(_ data: Data) -> Resolved? {
        var stale = false
        guard let (url, scoped) = resolveURL(data, stale: &stale),
              // Checked with access on: in the sandbox the folder can't even be looked at without it.
              withAccess([url], { isFolder(url) }) else { return nil }
        // The new bookmark must be made while access is on, or a sandboxed app can't create it.
        let refreshed = stale ? withAccess([url]) { usableBookmark(for: url) } : nil
        return Resolved(url: url, refreshed: refreshed, isSecurityScoped: scoped)
    }

    /// The file (not a folder) `data` points to now, or nil when it can't be found. A watermark image's bookmark.
    public static func resolveFile(_ data: Data) -> Resolved? {
        var stale = false
        guard let (url, scoped) = resolveURL(data, stale: &stale) else { return nil }
        var isDirectory: ObjCBool = false
        let exists = withAccess([url]) { FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) }
        guard exists, !isDirectory.boolValue else { return nil }
        let refreshed = stale ? withAccess([url]) { usableBookmark(for: url) } : nil
        return Resolved(url: url, refreshed: refreshed, isSecurityScoped: scoped)
    }

    /// Runs `body` with access to `urls` started (for those that are security-scoped) and stops it afterwards.
    public static func withAccess<T>(_ urls: [URL], _ body: () throws -> T) rethrows -> T {
        let grant = Grant(urls)
        defer { grant.release() }
        return try body()
    }

    public static func withAccess<T>(_ urls: [URL], _ body: () async throws -> T) async rethrows -> T {
        let grant = Grant(urls)
        defer { grant.release() }
        return try await body()
    }

    /// Access to `urls` for as long as it is held (a folder watcher's lifetime); released once.
    public final class Grant: @unchecked Sendable {
        private var started: [URL]
        private let lock = NSLock()
        /// How many of the URLs had security-scoped access started (a plain URL can't be started).
        public let startedCount: Int

        public init(_ urls: [URL]) {
            // A plain URL returns false here, and needs no stop.
            started = urls.filter { $0.startAccessingSecurityScopedResource() }
            startedCount = started.count
        }

        /// Whether this grant really gives access: outside the real sandbox any URL works; inside it only a
        /// started security scope does.
        public var givesAccess: Bool { !Sandbox.isEnforced || startedCount > 0 }

        deinit { release() }

        public func release() {
            lock.lock()
            let urls = started
            started = []
            lock.unlock()
            urls.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// A job's folders as they are now: resolved from their bookmarks, with stale bookmarks refreshed and
/// moved folders followed.
public enum JobFolders {
    public enum Outcome: Equatable, Sendable {
        /// The job as it should run (and, when `changed`, be saved: new URLs or bookmarks), and the URLs to start
        /// access on: the very instances the bookmarks resolved to (only those carry the sandbox's permission),
        /// or the plain URLs where there is no bookmark. Inputs first, then the new-folder output.
        case ready(Job, changed: Bool, access: [URL])
        /// A folder can't be found; `reason` says which, for the user.
        case unavailable(reason: String)
    }

    /// Bookmarks first; a folder without a usable bookmark keeps its plain URL when that folder exists (always the
    /// case outside the sandbox, where a bookmark is only a convenience). Missing bookmarks are created.
    public static func resolve(_ job: Job, sandboxed: Bool = FolderAccess.isSandboxed,
                               resolver: (Data) -> FolderAccess.Resolved? = FolderAccess.resolve,
                               bookmarker: (URL) -> Data? = FolderAccess.bookmark) -> Outcome {
        var updated = job
        var changed = false
        let stored = job.inputBookmarks?.count == job.inputs.count ? job.inputBookmarks : nil
        var bookmarks: [Data] = []
        var access: [URL] = []
        for (index, input) in job.inputs.enumerated() {
            switch folder(input, bookmark: stored?[index], sandboxed: sandboxed, resolver: resolver,
                          bookmarker: bookmarker) {
            case .none:
                return .unavailable(reason: "The input folder \u{201C}\(input.lastPathComponent)\u{201D} can't be found.")
            case .some(let found):
                if !same(found.url, input) { updated.inputs[index] = found.url; changed = true }
                access.append(found.access)
                if let data = found.bookmark { bookmarks.append(data) }
            }
        }
        let newBookmarks = bookmarks.count == job.inputs.count ? bookmarks : nil
        if newBookmarks != job.inputBookmarks { updated.inputBookmarks = newBookmarks; changed = true }

        switch resolveOutput(&updated, changed: &changed, sandboxed: sandboxed, resolver: resolver,
                             bookmarker: bookmarker) {
        case .failure(let failure): return .unavailable(reason: failure.reason)
        case .success(let output): return .ready(updated, changed: changed, access: access + (output.map { [$0] } ?? []))
        }
    }

    /// The folders that moved between `old` and `updated` (same job, inputs in the same order), for
    /// `JobStore.rebaseLedger`.
    public static func moves(from old: Job, to updated: Job) -> [(from: URL, to: URL)] {
        var moves = zip(old.inputs, updated.inputs).filter { !same($0.0, $0.1) }.map { (from: $0.0, to: $0.1) }
        if case .newFolder(let before) = old.output, case .newFolder(let after) = updated.output, !same(before, after) {
            moves.append((before, after))
        }
        return moves
    }

    /// A folder as it is now: the URL to store, the URL to access it through, and its bookmark.
    private struct Found {
        var url: URL
        var access: URL
        var bookmark: Data?
    }

    private struct Unavailable: Error {
        let reason: String
    }

    /// The output folder's access URL (nil when the output isn't a new folder), `job` updated; or why it can't be used.
    private static func resolveOutput(_ job: inout Job, changed: inout Bool, sandboxed: Bool,
                                      resolver: (Data) -> FolderAccess.Resolved?,
                                      bookmarker: (URL) -> Data?) -> Result<URL?, Unavailable> {
        guard case .newFolder(let root) = job.output else {
            if job.outputBookmark != nil { job.outputBookmark = nil; changed = true }
            return .success(nil)
        }
        // Only a bookmark that resolves somewhere else (the folder moved) changes the output.
        guard let found = folder(root, bookmark: job.outputBookmark, sandboxed: sandboxed, resolver: resolver,
                                 bookmarker: bookmarker, mayBeMissing: true) else {
            return .failure(Unavailable(reason: "The output folder \u{201C}\(root.lastPathComponent)\u{201D} can't be found."))
        }
        if !same(found.url, root) { job.output = .newFolder(found.url); changed = true }
        if found.bookmark != job.outputBookmark { job.outputBookmark = found.bookmark; changed = true }
        return .success(found.access)
    }

    /// The same folder, whatever the trailing slash or symlinked parent (`/tmp` and `/private/tmp`).
    private static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        WatchFilter.canonicalPath(lhs) == WatchFilter.canonicalPath(rhs)
    }

    private static func folder(_ url: URL, bookmark: Data?, sandboxed: Bool,
                               resolver: (Data) -> FolderAccess.Resolved?, bookmarker: (URL) -> Data?,
                               mayBeMissing: Bool = false) -> Found? {
        if let bookmark, let resolved = resolver(bookmark) {
            // Stored as the real path (`/private/tmp`, not `/tmp`), the form the watcher uses; accessed through the
            // resolved instance itself.
            let real = URL(fileURLWithPath: WatchFilter.canonicalPath(resolved.url), isDirectory: true)
            return Found(url: same(real, url) ? url : real, access: resolved.url, bookmark: resolved.refreshed ?? bookmark)
        }
        if FolderAccess.isFolder(url) {
            // Unsandboxed the plain URL is enough; sandboxed it works only while the app still has access.
            return Found(url: url, access: url, bookmark: bookmarker(url) ?? bookmark)
        }
        // Not there (yet): fine for a new output folder outside the sandbox, where the run creates it.
        if mayBeMissing && !sandboxed { return Found(url: url, access: url, bookmark: nil) }
        return nil
    }
}
