import AppKit
import Observation
import ImageconverterCore

/// The folders the sandboxed app may write into: folders the user allowed when a run asked (remembered as
/// app-scoped security-scoped bookmarks under `folderGrants`, see `FolderGrantList`), started at launch and kept
/// open for the app's lifetime; and this session's roots (folders dropped or added, the output folder, folders a
/// resumed batch opened again). A remembered folder only counts when its access really started (in the real
/// sandbox a bookmark that resolves without its security scope gives nothing). Before a run it asks, with a
/// pre-filled open panel, for each folder the run needs that none of these covers (`AccessPrompt`). Outside the
/// sandbox nothing is asked; bookmarks are still kept where they can be made.
@MainActor @Observable
final class AccessStore {
    static let shared = AccessStore(defaults: AppDefaults.store)
    static let key = "folderGrants"

    /// Most recently used first.
    var grants: [FolderGrantList.Grant] { list.grants }
    /// Paths of remembered folders whose bookmarks didn't resolve at launch (deleted, or on a volume that's gone).
    private(set) var unavailable: Set<String> = []
    /// Paths of remembered folders that resolve but whose access didn't start (sandbox): they must be allowed again.
    private(set) var needsAllowing: Set<String> = []

    private var list: FolderGrantList
    @ObservationIgnored private let defaults: UserDefaults
    /// Access started on remembered folders, by grant path; released on Remove.
    @ObservationIgnored private var held: [String: FolderAccess.Grant] = [:]
    /// The URLs whose access really started, by grant path (coverage uses these: they are where the folder is now).
    @ObservationIgnored private var resolved: [String: URL] = [:]
    @ObservationIgnored private(set) var sessionRoots: [URL] = []
    @ObservationIgnored private var sessionHeld: [FolderAccess.Grant] = []
    @ObservationIgnored private var activated = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        list = FolderGrantList(data: defaults.data(forKey: Self.key))
    }

    /// Resolves every remembered folder and starts access on it (once, at launch). Stale bookmarks are refreshed,
    /// moved folders followed (a move onto a folder already listed merges the two).
    func activate() {
        guard !activated else { return }
        activated = true
        var changed = false
        var index = 0
        while index < list.grants.count {
            let grant = list.grants[index]
            guard let found = FolderAccess.resolve(grant.bookmark) else {
                unavailable.insert(grant.path)
                index += 1
                continue
            }
            let path = found.url.standardizedFileURL.path
            if path != grant.path || found.refreshed != nil {
                let removed = list.update(at: index, path: path, bookmark: found.refreshed ?? grant.bookmark)
                removed.forEach(forget)
                changed = true
                // Removing earlier duplicates shifts this grant; find it again.
                index = list.grants.firstIndex { $0.path == path } ?? index
            }
            start(path: path, url: found.url, scoped: found.isSecurityScoped)
            index += 1
        }
        if changed { save() }
    }

    /// Starts access on a remembered folder; it counts as covered only when that really gives access.
    private func start(path: String, url: URL, scoped: Bool) {
        held.removeValue(forKey: path)?.release()
        let grant = FolderAccess.Grant([url])
        held[path] = grant
        if (scoped || !Sandbox.isEnforced) && grant.givesAccess {
            resolved[path] = url
            needsAllowing.remove(path)
        } else {
            resolved.removeValue(forKey: path)
            needsAllowing.insert(path)
        }
    }

    private func forget(_ path: String) {
        held.removeValue(forKey: path)?.release()
        resolved.removeValue(forKey: path)
        unavailable.remove(path)
        needsAllowing.remove(path)
    }

    /// Everything that counts as allowed right now.
    var covered: [URL] { Array(resolved.values) + sessionRoots }

    // MARK: Session roots

    /// Dropped or added items: folders cover their contents this session (a dropped file covers only itself,
    /// not the folder it is in).
    func noteAdded(_ urls: [URL]) {
        for url in urls where Self.isFolder(url) { addSessionRoot(url) }
    }

    func addSessionRoot(_ url: URL) {
        let url = url.standardizedFileURL
        guard !sessionRoots.contains(url) else { return }
        sessionRoots.append(url)
    }

    /// Starts access on `urls` (resolved bookmarks) for the rest of the session and counts those that really
    /// opened as covered. Returns the ones that didn't open (sandbox).
    func holdForSession(_ urls: [URL]) -> [URL] {
        var failed: [URL] = []
        for url in urls {
            let grant = FolderAccess.Grant([url])
            if grant.givesAccess {
                sessionHeld.append(grant)
                addSessionRoot(url)
            } else {
                grant.release()
                failed.append(url)
            }
        }
        return failed
    }

    /// Starts access on loose files (a resumed batch's file bookmarks) for the rest of the session. They don't
    /// count as covered folders: each opens only itself.
    func holdFilesForSession(_ urls: [URL]) {
        for url in urls {
            let grant = FolderAccess.Grant([url])
            if grant.givesAccess { sessionHeld.append(grant) } else { grant.release() }
        }
    }

    // MARK: Remembered folders

    /// Remembers `url` (chosen in an open panel, so the app has access to it now) as most recently used. Only a
    /// bookmark that will open it again is kept (security-scoped in the sandbox); either way the folder counts for
    /// this session.
    func remember(_ url: URL) {
        addSessionRoot(url)
        guard let data = FolderAccess.usableBookmark(for: url) else { return }
        let path = url.standardizedFileURL.path
        let dropped = list.insert(path: path, bookmark: data)
        dropped.forEach { forget($0.path) }
        // Any older entry for the same folder under another spelling was replaced.
        for stale in held.keys where !list.grants.contains(where: { $0.path == stale }) { forget(stale) }
        unavailable.remove(path)
        // Started through the bookmark itself, so the list shows whether it will work after a relaunch.
        if let found = FolderAccess.resolve(data) {
            start(path: path, url: found.url, scoped: found.isSecurityScoped)
        } else {
            needsAllowing.insert(path)
        }
        save()
    }

    func remove(_ path: String) {
        list.remove(path: path)
        forget(path)
        save()
    }

    func removeAll() {
        list.removeAll()
        for path in Array(held.keys) { forget(path) }
        unavailable = []
        needsAllowing = []
        save()
    }

    /// Marks the remembered folders that contain any of `folders` as just used (they stay longest).
    private func touch(covering folders: [URL]) {
        let indices = list.grants.indices.filter { resolved[list.grants[$0].path] != nil }
        let used = AccessNeeds.roots(indices.compactMap { resolved[list.grants[$0].path] }, covering: folders)
        guard !used.isEmpty else { return }
        list.touch(Set(used.map { indices[$0] }))
        save()
    }

    private func save() {
        if let data = list.encoded() { defaults.set(data, forKey: Self.key) }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Before a run

    /// Asks for each folder `sources` in `mode` need that isn't covered (see `AccessPrompt`). False when the user
    /// cancels: the run must not start, and unless `quiet` a toast says why. Always true outside the sandbox.
    func ensureAccess(sources: [URL], mode: OutputMode, toasts: LGToastCenter, quiet: Bool = false) async -> Bool {
        guard Sandbox.isActive else { return true }
        activate()
        var unreadable = Set<String>()
        if case .newFolder = mode {
            // One check per folder, off the main actor (batches can hold 100 000 files).
            unreadable = await Task.detached(priority: .userInitiated) {
                AccessPrompt.unreadableFolders(of: sources)
            }.value
        }
        let outcome = AccessPrompt.run(sources: sources, mode: mode, covered: covered, unreadableFolders: unreadable,
                                       ask: { need, again in self.ask(for: need, again: again) },
                                       accept: { self.remember($0) })
        switch outcome {
        case .granted:
            touch(covering: Self.folders(sources: sources, mode: mode))
            return true
        case .refused(let need):
            if !quiet {
                toasts.show("Not run: no access to \u{201C}\(need.folder.lastPathComponent)\u{201D}", type: .info,
                            description: "imageconverter can only \(Self.verb(need.purpose)) in folders you allow. "
                                + "Run again and choose the folder to allow it.")
            }
            return false
        }
    }

    /// Resuming: asks for the folders of `unreadable` sources none of the allowed folders covers (sandbox only;
    /// see `AccessPrompt.askToRead`). Returns the folders the user didn't allow.
    func askToRead(_ unreadable: [URL]) -> [URL] {
        guard Sandbox.isActive, !unreadable.isEmpty else { return [] }
        activate()
        return AccessPrompt.askToRead(unreadable, covered: covered,
                                      ask: { need, again in self.ask(for: need, again: again) },
                                      accept: { self.remember($0) })
    }

    /// The folders a run touches, for `touch`.
    private static func folders(sources: [URL], mode: OutputMode) -> [URL] {
        if case .newFolder(let output) = mode { return [output] }
        var seen = Set<String>()
        return sources.map { $0.deletingLastPathComponent() }.filter { seen.insert($0.path).inserted }
    }

    /// The open panel's message.
    static func message(for need: AccessNeeds.Need, again: Bool = false) -> String {
        let name = need.folder.lastPathComponent
        let first = again ? "The folder you chose doesn't contain \u{201C}\(name)\u{201D}. " : ""
        return first + "imageconverter needs access to \u{201C}\(name)\u{201D} to \(verb(need.purpose)). "
            + "Choose this folder (or one that contains it) to allow it."
    }

    private static func verb(_ purpose: AccessNeeds.Purpose) -> String {
        switch purpose {
        case .saveNextToOriginals: return "save next to the originals"
        case .replaceOriginals: return "replace the originals"
        case .saveToOutputFolder: return "save the converted images"
        case .readOriginals: return "read the images"
        }
    }

    /// The open panel, opened on the folder itself so "Allow" with nothing selected picks it.
    private func ask(for need: AccessNeeds.Need, again: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = need.purpose == .saveToOutputFolder
        panel.allowsMultipleSelection = false
        panel.directoryURL = need.folder
        panel.message = Self.message(for: need, again: again)
        panel.prompt = "Allow"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
