import Foundation

/// The question loop before a run, without the UI: ask for the first folder still needed, count the answer only
/// when it contains that folder (an unrelated folder is neither used nor remembered, and the same folder is asked
/// again saying so), re-check what is still needed after every answer (a folder that contains several needed
/// ones answers them all), and stop at the first Cancel or after `maxTries` wrong answers for one folder.
public enum AccessPrompt {
    public enum Outcome: Equatable, Sendable {
        case granted
        /// The user cancelled (or kept choosing other folders) for this folder; the run must not start.
        case refused(AccessNeeds.Need)
    }

    public static let maxTries = 3

    /// `ask(need, again)` shows the question (`again`: the previous answer didn't contain the folder) and returns
    /// the chosen folder, or nil for Cancel. `accept(folder)` is called for each answer that is used (remember it).
    /// `unreadableFolders`: new-folder mode, the sources' folders that can't be read now (see `unreadableFolders`).
    public static func run(sources: [URL], mode: OutputMode, covered: [URL], unreadableFolders: Set<String> = [],
                           caseSensitive: Bool? = nil, ask: (AccessNeeds.Need, Bool) -> URL?,
                           accept: (URL) -> Void) -> Outcome {
        var covered = covered
        var wrongAnswers: [String: Int] = [:]
        let isReadable: (URL) -> Bool = { !unreadableFolders.contains(folderKey($0.deletingLastPathComponent())) }
        while let need = AccessNeeds.needs(sources: sources, mode: mode, covered: covered, isReadable: isReadable,
                                           caseSensitive: caseSensitive).first {
            let wrong = wrongAnswers[need.folder.path, default: 0]
            guard wrong < maxTries, let chosen = ask(need, wrong > 0) else { return .refused(need) }
            guard AccessNeeds.isCovered(need.folder, by: chosen, caseSensitive: caseSensitive) else {
                wrongAnswers[need.folder.path] = wrong + 1
                continue
            }
            accept(chosen)
            covered.append(chosen)
        }
        return .granted
    }

    /// Resuming an interrupted batch: asks for the folders of the `unreadable` sources that no folder in `covered`
    /// contains (`.readOriginals`), with the same rules as `run`. Returns the folders still not allowed when it
    /// stops (empty when everything was allowed): after a Cancel, that folder and every one not asked yet.
    public static func askToRead(_ unreadable: [URL], covered: [URL], caseSensitive: Bool? = nil,
                                 ask: (AccessNeeds.Need, Bool) -> URL?, accept: (URL) -> Void) -> [URL] {
        var covered = covered
        var wrongAnswers: [String: Int] = [:]
        while true {
            let needs = AccessNeeds.readingNeeds(unreadable, covered: covered, caseSensitive: caseSensitive)
            guard let need = needs.first else { return [] }
            let wrong = wrongAnswers[need.folder.path, default: 0]
            guard wrong < maxTries, let chosen = ask(need, wrong > 0) else { return needs.map(\.folder) }
            guard AccessNeeds.isCovered(need.folder, by: chosen, caseSensitive: caseSensitive) else {
                wrongAnswers[need.folder.path] = wrong + 1
                continue
            }
            accept(chosen)
            covered.append(chosen)
        }
    }

    /// The folders (standardised paths) of `sources` whose first file can't be read: one check per folder, so a
    /// batch of 100 000 files costs a few hundred calls. Run it off the main actor.
    public static func unreadableFolders(of sources: [URL],
                                         isReadable: (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) })
        -> Set<String> {
        var checked = Set<String>()
        var unreadable = Set<String>()
        for source in sources {
            let key = folderKey(source.deletingLastPathComponent())
            guard checked.insert(key).inserted else { continue }
            if !isReadable(source) { unreadable.insert(key) }
        }
        return unreadable
    }

    static func folderKey(_ folder: URL) -> String { folder.standardizedFileURL.path }
}

/// The remembered folder grants (UserDefaults `folderGrants`): most recently used first, at most `maxGrants`, one
/// per folder (by file identity, so a moved folder or another spelling isn't listed twice). Untrusted on load.
public struct FolderGrantList: Equatable, Sendable {
    public struct Grant: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var bookmark: Data
        public var lastUsed: Date
        public var id: String { path }
        public var name: String { URL(fileURLWithPath: path).lastPathComponent }

        public init(path: String, bookmark: Data, lastUsed: Date) {
            self.path = path
            self.bookmark = bookmark
            self.lastUsed = lastUsed
        }
    }

    public static let maxGrants = 200

    /// Most recently used first.
    public private(set) var grants: [Grant]
    private let identity: @Sendable (String) -> String

    public static func == (lhs: FolderGrantList, rhs: FolderGrantList) -> Bool { lhs.grants == rhs.grants }

    /// `identity` says which paths are the same folder (default `FileIdentity.key`; injected in tests).
    public init(grants: [Grant] = [],
                identity: @escaping @Sendable (String) -> String = { FileIdentity.key(URL(fileURLWithPath: $0)) }) {
        self.identity = identity
        self.grants = []
        for grant in grants.sorted(by: { $0.lastUsed > $1.lastUsed }) { _ = add(grant) }
    }

    /// Stored data, validated: undecodable gives none; only absolute paths and real-sized bookmarks; newest
    /// `maxGrants` kept; duplicates dropped.
    public init(data: Data?,
                identity: @escaping @Sendable (String) -> String = { FileIdentity.key(URL(fileURLWithPath: $0)) }) {
        let decoded = data.flatMap { try? JSONDecoder().decode([Grant].self, from: $0) } ?? []
        let valid = decoded.filter {
            $0.path.hasPrefix("/") && $0.path.utf8.count <= 4096 && !$0.path.unicodeScalars.contains { $0.value == 0 }
                && !$0.bookmark.isEmpty && $0.bookmark.count <= FolderAccess.maxBookmarkSize
        }
        self.init(grants: valid, identity: identity)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(grants) }

    /// Adds or renews the grant for `path` as most recently used. Returns the grants dropped to stay within
    /// `maxGrants` (release their access).
    @discardableResult
    public mutating func insert(path: String, bookmark: Data, now: Date = Date()) -> [Grant] {
        let key = identity(path)
        grants.removeAll { $0.path == path || identity($0.path) == key }
        grants.insert(Grant(path: path, bookmark: bookmark, lastUsed: now), at: 0)
        guard grants.count > Self.maxGrants else { return [] }
        let dropped = Array(grants[Self.maxGrants...])
        grants.removeLast(grants.count - Self.maxGrants)
        return dropped
    }

    /// Updates the grant at `index` (a refreshed bookmark or a followed move); a move onto a folder already listed
    /// drops the older entry. Returns the paths removed that way.
    @discardableResult
    public mutating func update(at index: Int, path: String, bookmark: Data) -> [String] {
        guard grants.indices.contains(index) else { return [] }
        grants[index].path = path
        grants[index].bookmark = bookmark
        let key = identity(path)
        let duplicates = grants.indices.filter { $0 != index && (grants[$0].path == path || identity(grants[$0].path) == key) }
        let removed = duplicates.map { grants[$0].path }
        let kept = grants[index]
        grants.removeAll { removed.contains($0.path) && $0 != kept }
        return removed
    }

    /// Marks the grants at `indices` as used `now`, then re-sorts by use.
    public mutating func touch(_ indices: Set<Int>, now: Date = Date()) {
        guard !indices.isEmpty else { return }
        for index in indices where grants.indices.contains(index) { grants[index].lastUsed = now }
        grants.sort { $0.lastUsed > $1.lastUsed }
    }

    public mutating func remove(path: String) { grants.removeAll { $0.path == path } }

    public mutating func removeAll() { grants = [] }

    /// Adds a grant that isn't a duplicate, keeping order; false when it is, or the list is full.
    private mutating func add(_ grant: Grant) -> Bool {
        guard grants.count < Self.maxGrants else { return false }
        let key = identity(grant.path)
        guard !grants.contains(where: { $0.path == grant.path || identity($0.path) == key }) else { return false }
        grants.append(grant)
        return true
    }
}
