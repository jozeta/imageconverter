import Foundation

/// The adds still being scanned for the app's image list, and what each one does when its scan ends: the new items
/// are merged into the list in one change (not one per file), dropped when a Clear came after the add started, or
/// kept until the run ends when a run started meanwhile (nothing joins a running batch).
public struct ItemAdds: Sendable {
    /// One add in progress, from `begin`.
    public struct Token: Sendable, Equatable {
        fileprivate let generation: Int
    }

    /// A scan's result, prepared off the main actor (`prepare`): the files' keys are read there (a stat per file),
    /// against the list as it was when the scan started.
    public struct Found: Sendable, Equatable {
        /// Every item the scan found.
        public let all: [InputItem]
        /// The items of `all` whose file wasn't in `snapshot`.
        public let new: [InputItem]
        /// The list's sources `new` was worked out against.
        public let snapshot: [URL]
    }

    /// What a finished scan does to the list.
    public enum Outcome: Equatable, Sendable {
        /// Set the list to this (the existing items first, then the new ones).
        case replace([InputItem])
        /// Everything found is listed already: leave the list alone.
        case unchanged
        /// A Clear came after the add started: nothing changes.
        case dropped
        /// A run is in progress: this many found items wait for `takeQueued`.
        case queued(Int)
    }

    /// The list after merging, and how many items were new.
    public struct Merge: Equatable, Sendable {
        public let items: [InputItem]
        public let added: Int
    }

    private var generation = 0
    private var pending = 0
    private var queued: [InputItem] = []

    public init() {}

    /// True while a scan that still counts is in progress.
    public var isAdding: Bool { pending > 0 }
    /// True when found items wait for the run to end.
    public var hasQueued: Bool { !queued.isEmpty }

    /// Starts an add; pass the token to `finish` when its scan ends.
    public mutating func begin() -> Token {
        pending += 1
        return Token(generation: generation)
    }

    /// Ends every add in progress (their results are dropped) and forgets queued items.
    public mutating func clear() {
        generation += 1
        pending = 0
        queued = []
    }

    /// Works out which of `found` are new against `existing` (call it off the main actor: it stats every file).
    public static func prepare(_ found: [InputItem], against existing: [InputItem]) -> Found {
        Found(all: found, new: newItems(found, against: existing), snapshot: existing.map(\.source))
    }

    /// The scan for `token` found `found`; `existing` is the list now, `running` whether a run is in progress. When the
    /// list still has the sources `found` was prepared against, nothing is read from disk here; otherwise the new items
    /// are worked out again against the list as it is now.
    public mutating func finish(_ token: Token, found: Found, existing: [InputItem], running: Bool) -> Outcome {
        guard token.generation == generation else { return .dropped }
        pending = max(0, pending - 1)
        if running {
            queued += found.all
            return .queued(found.all.count)
        }
        let new = existing.map(\.source) == found.snapshot ? found.new : Self.newItems(found.all, against: existing)
        return new.isEmpty ? .unchanged : .replace(existing + new)
    }

    /// The queued items merged into `existing` (nil when nothing new waits); called when the run ends.
    public mutating func takeQueued(existing: [InputItem]) -> Merge? {
        guard !queued.isEmpty else { return nil }
        let new = Self.newItems(queued, against: existing)
        queued = []
        return new.isEmpty ? nil : Merge(items: existing + new, added: new.count)
    }

    /// Every item of `found` whose file isn't listed in `existing` yet (by file, not by item: a file added loose and
    /// again through its folder is listed once).
    static func newItems(_ found: [InputItem], against existing: [InputItem]) -> [InputItem] {
        var seen = Set(existing.map(\.fileKey))
        return found.filter { seen.insert($0.fileKey).inserted }
    }
}
