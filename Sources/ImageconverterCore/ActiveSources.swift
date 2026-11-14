import Foundation

/// The sources batches in this process are working on right now (manual runs, Services, scripts, links and
/// jobs). A run claims its files when it starts; a file another run already holds is skipped with
/// `busyReason` instead of being processed twice (in overwrite mode both would replace the same original).
/// Another process (the command-line tool) isn't coordinated; its own job lock still keeps one job to one runner.
public final class ActiveSources: @unchecked Sendable {
    public static let shared = ActiveSources()
    public static let busyReason = "Busy in another run"

    private let lock = NSLock()
    private var held = Set<String>()

    init() {}

    /// Claims every key not already held and returns the ones that were (busy), in input order.
    func claim(_ keys: [String]) -> (claimed: [String], busy: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        var claimed: [String] = []
        var busy = Set<String>()
        for key in keys {
            if held.insert(key).inserted { claimed.append(key) } else { busy.insert(key) }
        }
        return (claimed, busy)
    }

    func release(_ keys: [String]) {
        lock.lock()
        defer { lock.unlock() }
        held.subtract(keys)
    }

    /// True while some run holds `url` (tests).
    func isHeld(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held.contains(InputItem(source: url, relativeDirectory: "").fileKey)
    }
}
