import AppKit
import Observation
import ImageconverterCore

/// The folders the sandboxed app may write into: folders the user allowed when a run asked (remembered as
/// app-scoped security-scoped bookmarks under `folderGrants`, at most `maxGrants`, least recently used dropped
/// first), started at launch and kept open for the app's lifetime; and this session's roots (folders dropped or
/// added, the output folder, folders a resumed batch opened again). Before a run it asks, with a pre-filled open
/// panel, for each folder the run needs that none of these covers. Outside the sandbox nothing is asked; bookmarks
/// are still kept, so the same grants work once the app is sandboxed.
@MainActor @Observable
final class AccessStore {
    static let shared = AccessStore(defaults: AppDefaults.store)
    static let key = "folderGrants"
    static let maxGrants = 200

    struct Grant: Codable, Equatable, Identifiable {
        var path: String
        var bookmark: Data
        var lastUsed: Date
        var id: String { path }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    /// Most recently used first.
    private(set) var grants: [Grant] = []
    /// Paths of remembered folders whose bookmarks didn't resolve at launch (deleted, or on a volume that's gone).
    private(set) var unavailable: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults
    /// Access started on remembered folders and resolved bookmarks, by path; released on Remove.
    @ObservationIgnored private var held: [String: FolderAccess.Grant] = [:]
    /// The URLs access was started on, by grant path (coverage uses these: they are where the folder is now).
    @ObservationIgnored private var resolved: [String: URL] = [:]
    @ObservationIgnored private(set) var sessionRoots: [URL] = []
    @ObservationIgnored private var sessionHeld: [FolderAccess.Grant] = []
    @ObservationIgnored private var activated = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        grants = Self.load(from: defaults)
    }

    /// Resolves every remembered folder and starts access on it (once, at launch). Stale bookmarks are refreshed
    /// and moved folders followed.
    func activate() {
        guard !activated else { return }
        activated = true
        var changed = false
        for index in grants.indices {
            guard let found = FolderAccess.resolve(grants[index].bookmark) else {
                unavailable.insert(grants[index].path)
                continue
            }
            if let refreshed = found.refreshed { grants[index].bookmark = refreshed; changed = true }
            let path = found.url.standardizedFileURL.path
            if path != grants[index].path { grants[index].path = path; changed = true }
            held[path] = FolderAccess.Grant([found.url])
            resolved[path] = found.url
        }
        if changed { save() }
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

    /// Starts access on `urls` (resolved bookmarks) for the rest of the session and counts them as covered.
    func holdForSession(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        sessionHeld.append(FolderAccess.Grant(urls))
        urls.forEach(addSessionRoot)
    }

    // MARK: Remembered folders

    /// Remembers `url` (chosen in an open panel, so the app has access to it now): bookmark, access for the
    /// session, most recently used. False when no bookmark could be made.
    @discardableResult
    func remember(_ url: URL) -> Bool {
        guard let data = FolderAccess.bookmark(for: url) else { return false }
        let path = url.standardizedFileURL.path
        grants.removeAll { $0.path == path }
        grants.insert(Grant(path: path, bookmark: data, lastUsed: Date()), at: 0)
        unavailable.remove(path)
        held[path]?.release()
        held[path] = FolderAccess.Grant([url])
        resolved[path] = url
        trim()
        save()
        return true
    }

    func remove(_ path: String) {
        grants.removeAll { $0.path == path }
        unavailable.remove(path)
        held.removeValue(forKey: path)?.release()
        resolved.removeValue(forKey: path)
        save()
    }

    func removeAll() {
        grants = []
        unavailable = []
        held.values.forEach { $0.release() }
        held = [:]
        resolved = [:]
        save()
    }

    /// Marks the remembered folders that contain any of `folders` as just used (they stay longest).
    private func touch(covering folders: [URL]) {
        let indices = grants.indices.filter { resolved[grants[$0].path] != nil }
        let used = AccessNeeds.roots(indices.compactMap { resolved[grants[$0].path] }, covering: folders)
        guard !used.isEmpty else { return }
        let now = Date()
        for position in used { grants[indices[position]].lastUsed = now }
        grants.sort { $0.lastUsed > $1.lastUsed }
        save()
    }

    private func trim() {
        grants.sort { $0.lastUsed > $1.lastUsed }
        while grants.count > Self.maxGrants {
            let dropped = grants.removeLast()
            held.removeValue(forKey: dropped.path)?.release()
            resolved.removeValue(forKey: dropped.path)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(grants) { defaults.set(data, forKey: Self.key) }
    }

    /// Untrusted like any stored file: undecodable data gives no grants; at most `maxGrants`, absolute paths only.
    private static func load(from defaults: UserDefaults) -> [Grant] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Grant].self, from: data) else { return [] }
        let valid = decoded.filter { $0.path.hasPrefix("/") && !$0.bookmark.isEmpty
            && $0.bookmark.count <= ImageWatermark.maxBookmarkSize }
        return Array(valid.sorted { $0.lastUsed > $1.lastUsed }.prefix(maxGrants))
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Before a run

    /// Asks for each folder `sources` in `mode` need that isn't covered, one pre-filled open panel at a time,
    /// re-checking after each answer (a folder that contains several needed ones covers them all). False when the
    /// user cancels (the run must not start; a toast says why). Always true outside the sandbox.
    func ensureAccess(sources: [URL], mode: OutputMode, toasts: LGToastCenter) -> Bool {
        guard Sandbox.isActive else { return true }
        activate()
        let isReadable: (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) }
        var attempts: [String: Int] = [:]
        while let need = AccessNeeds.needs(sources: sources, mode: mode, covered: covered, isReadable: isReadable).first {
            let tries = attempts[need.folder.path, default: 0]
            attempts[need.folder.path] = tries + 1
            guard tries < 3, let chosen = ask(for: need, again: tries > 0) else {
                toasts.show("Not run: no access to \u{201C}\(need.folder.lastPathComponent)\u{201D}", type: .info,
                            description: "imageconverter can only \(Self.verb(need.purpose)) in folders you allow. "
                                + "Run again and choose the folder to allow it.")
                return false
            }
            if !remember(chosen) { addSessionRoot(chosen) }
        }
        touch(covering: Self.folders(sources: sources, mode: mode))
        return true
    }

    /// The folders a run touches, for `touch`.
    private static func folders(sources: [URL], mode: OutputMode) -> [URL] {
        if case .newFolder(let output) = mode { return [output] }
        var seen = Set<String>()
        return sources.map { $0.deletingLastPathComponent() }.filter { seen.insert($0.path).inserted }
    }

    /// The question's wording, also used for the open panel's message.
    static func message(for need: AccessNeeds.Need, again: Bool = false) -> String {
        let name = need.folder.lastPathComponent
        let first = again
            ? "The folder you chose doesn't contain \u{201C}\(name)\u{201D}. "
            : ""
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
