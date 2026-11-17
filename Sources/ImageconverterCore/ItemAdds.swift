import Foundation

/// The adds still being scanned for the app's image list, and what each one does when its scan ends: the found items
/// are merged into the list in one change (not one per file), dropped when a Clear came after the add started, or
/// kept until the run ends when a run started meanwhile (nothing joins a running batch).
public struct ItemAdds: Sendable {
    /// One add in progress, from `begin`.
    public struct Token: Sendable, Equatable {
        fileprivate let generation: Int
    }

    /// What a finished scan does to the list.
    public enum Outcome: Equatable, Sendable {
        /// Set the list to this (the existing items first, then the new ones).
        case replace([InputItem])
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

    /// The scan for `token` found `found`; `existing` is the list now, `running` whether a run is in progress.
    public mutating func finish(_ token: Token, found: [InputItem], existing: [InputItem], running: Bool) -> Outcome {
        guard token.generation == generation else { return .dropped }
        pending = max(0, pending - 1)
        if running {
            queued += found
            return .queued(found.count)
        }
        return .replace(Self.merge(found, into: existing).items)
    }

    /// The queued items merged into `existing` (nil when nothing new waits); called when the run ends.
    public mutating func takeQueued(existing: [InputItem]) -> Merge? {
        guard !queued.isEmpty else { return nil }
        let merged = Self.merge(queued, into: existing)
        queued = []
        return merged.added > 0 ? merged : nil
    }

    /// `existing` followed by every item of `found` whose file isn't listed yet (by file, not by item: a file added
    /// loose and again through its folder is listed once).
    public static func merge(_ found: [InputItem], into existing: [InputItem]) -> Merge {
        var seen = Set(existing.map(\.fileKey))
        let new = found.filter { seen.insert($0.fileKey).inserted }
        return Merge(items: existing + new, added: new.count)
    }
}
