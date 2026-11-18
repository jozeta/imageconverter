import Foundation

/// The output paths batches in this process have planned and not yet finished with. A run claims each name it
/// plans, so two runs at once (a manual run next to a job, several Shortcuts actions, a Service or a script)
/// never plan the same name; a commit that must pick another name claims it too. Keyed by
/// `FileIdentity.pathKey`, as the volume compares names. Another process isn't coordinated: there the
/// exclusive rename in `FileCommitter` still refuses to replace anything.
public enum PlannedDestinations {
    private static let state = HeldPaths()

    /// Claims `url`; false when some run already holds it.
    public static func claim(_ url: URL) -> Bool { claimKey(FileIdentity.pathKey(url)) != nil }

    /// Gives `url` back; only its claimer calls this, once.
    public static func release(_ url: URL) { releaseKey(FileIdentity.pathKey(url)) }

    /// Claims `url` and returns the key it is held under (nil when taken). The key is worked out once, at claim
    /// time: a folder created later (or the volume's case rule read then) can't make the release miss it.
    static func claimKey(_ url: URL) -> String? {
        let key = FileIdentity.pathKey(url)
        return claimKey(key)
    }

    private static func claimKey(_ key: String) -> String? { state.insert(key) ? key : nil }

    static func releaseKey(_ key: String) { state.remove(key) }

    /// True while some run holds `url` (tests).
    static func isClaimed(_ url: URL) -> Bool { state.contains(FileIdentity.pathKey(url)) }
}

/// One run's claims in `PlannedDestinations`, so each is released exactly once: per item when it finishes, and
/// every one left when the run ends (also after a cancel or a failed plan).
final class DestinationClaims: @unchecked Sendable {
    private let lock = NSLock()
    /// Registry key by the claimed URL's standardized path.
    private var held: [String: String] = [:]

    /// Claims `url` for this run; false when another run (or this one) already holds it.
    func claim(_ url: URL) -> Bool {
        guard let key = PlannedDestinations.claimKey(url) else { return false }
        lock.lock()
        held[url.standardizedFileURL.path] = key
        lock.unlock()
        return true
    }

    /// Releases those of `urls` (as claimed) this run still holds.
    func release(_ urls: [URL]) {
        lock.lock()
        let owned = urls.compactMap { held.removeValue(forKey: $0.standardizedFileURL.path) }
        lock.unlock()
        owned.forEach(PlannedDestinations.releaseKey)
    }

    /// Releases everything this run still holds.
    func releaseAll() {
        lock.lock()
        let owned = Array(held.values)
        held.removeAll()
        lock.unlock()
        owned.forEach(PlannedDestinations.releaseKey)
    }
}

/// A lock-protected set of path keys.
private final class HeldPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()

    func insert(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.insert(key).inserted
    }

    func remove(_ key: String) {
        lock.lock()
        keys.remove(key)
        lock.unlock()
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.contains(key)
    }
}
