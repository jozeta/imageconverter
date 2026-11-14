import Foundation

/// What identifies one version of a file: a file is processed once unless its size or modification date changes.
public struct FileFingerprint: Hashable, Codable, Sendable {
    public var path: String
    public var size: Int
    /// Seconds since 1970 (a Double round-trips exactly through JSON).
    public var modified: Double

    public init(path: String, size: Int, modified: Double) {
        self.path = path
        self.size = size
        self.modified = modified
    }

    /// The fingerprint of a regular file on disk; nil when it isn't one or can't be read.
    public static func of(_ url: URL) -> FileFingerprint? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return FileFingerprint(path: url.path, size: size, modified: modified.timeIntervalSince1970)
    }
}

/// What a job knows about files: inputs it processed (or tried to) and files it wrote. A file is skipped when this
/// exact version succeeded, failed `maxAttempts` times, or was written by the job. Inputs and outputs have their own
/// cap of `maxEntries` (oldest dropped), so pruning old inputs never turns an old output back into an input.
public struct ProcessedLedger: Codable, Equatable, Sendable {
    public static let maxEntries = 100_000
    /// A file that failed this often (unchanged) is left alone until it changes.
    public static let maxAttempts = 3
    public static let schemaVersion = 2

    /// `failures` 0: processed; otherwise the failed attempts of this version.
    private struct Entry: Equatable, Sendable {
        var fingerprint: FileFingerprint
        var failures: Int
        var order: Int
    }

    private var inputs: [String: Entry] = [:]
    private var outputs: [String: Entry] = [:]
    private var nextOrder = 0

    public init() {}

    public var count: Int { inputs.count }
    public var outputCount: Int { outputs.count }

    /// True when the file needs no (further) attempt: done, given up, or one of the job's outputs.
    public func isSettled(_ fingerprint: FileFingerprint) -> Bool {
        if outputs[fingerprint.path]?.fingerprint == fingerprint { return true }
        guard let entry = inputs[fingerprint.path], entry.fingerprint == fingerprint else { return false }
        return entry.failures == 0 || entry.failures >= Self.maxAttempts
    }

    /// Failed attempts of this exact version (0 when it never failed or has changed).
    public func failures(of fingerprint: FileFingerprint) -> Int {
        guard let entry = inputs[fingerprint.path], entry.fingerprint == fingerprint else { return 0 }
        return entry.failures
    }

    /// Records processed inputs; an older version of the same path is replaced.
    public mutating func recordProcessed(_ fingerprints: [FileFingerprint]) {
        for fingerprint in fingerprints {
            Self.insert(Entry(fingerprint: fingerprint, failures: 0, order: 0), into: &inputs, order: &nextOrder)
        }
        Self.trim(&inputs)
    }

    /// Records a failed attempt and returns the attempts so far for this version (a changed file starts at 1).
    @discardableResult
    public mutating func recordFailure(_ fingerprint: FileFingerprint) -> Int {
        let attempts = failures(of: fingerprint) + 1
        Self.insert(Entry(fingerprint: fingerprint, failures: attempts, order: 0), into: &inputs, order: &nextOrder)
        Self.trim(&inputs)
        return attempts
    }

    /// Records files the job wrote, so they are never taken as inputs.
    public mutating func recordOutputs(_ fingerprints: [FileFingerprint]) {
        for fingerprint in fingerprints {
            Self.insert(Entry(fingerprint: fingerprint, failures: 0, order: 0), into: &outputs, order: &nextOrder)
        }
        Self.trim(&outputs)
    }

    /// A watched folder moved (its bookmark followed it): entries under `old` now live under `new`, so the files
    /// in it are not processed (and in overwrite mode re-compressed) again.
    public mutating func rebase(from old: String, to new: String) {
        guard old != new else { return }
        let prefix = old.hasSuffix("/") ? old : old + "/"
        let target = new.hasSuffix("/") ? new : new + "/"
        func move(_ table: inout [String: Entry]) {
            for (path, entry) in table where path.hasPrefix(prefix) {
                var moved = entry
                moved.fingerprint.path = target + path.dropFirst(prefix.count)
                table[path] = nil
                table[moved.fingerprint.path] = moved
            }
        }
        move(&inputs)
        move(&outputs)
    }

    /// Sets the entry's place in the recording order and stores it under its path.
    private static func insert(_ entry: Entry, into table: inout [String: Entry], order: inout Int) {
        var entry = entry
        entry.order = order
        order += 1
        table[entry.fingerprint.path] = entry
    }

    private static func trim(_ table: inout [String: Entry]) {
        let excess = table.count - maxEntries
        guard excess > 0 else { return }
        for (path, _) in table.sorted(by: { $0.value.order < $1.value.order }).prefix(excess) { table[path] = nil }
    }

    private static func sorted(_ table: [String: Entry]) -> [Entry] { table.values.sorted { $0.order < $1.order } }

    /// Inputs, oldest first.
    public var fingerprints: [FileFingerprint] { Self.sorted(inputs).map(\.fingerprint) }
    /// Outputs, oldest first.
    public var outputFingerprints: [FileFingerprint] { Self.sorted(outputs).map(\.fingerprint) }

    /// Same entries in the same order (the recording counter itself doesn't matter).
    public static func == (lhs: ProcessedLedger, rhs: ProcessedLedger) -> Bool {
        stored(lhs.inputs) == stored(rhs.inputs) && stored(lhs.outputs) == stored(rhs.outputs)
    }

    // MARK: Coding

    private struct StoredEntry: Codable, Equatable {
        var path: String
        var size: Int
        var modified: Double
        var failures: Int?
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, entries, outputs }

    /// Version 1 files (no failures, no outputs) load as all processed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Unsupported ledger version")
        }
        let entries = try container.decode([StoredEntry].self, forKey: .entries)
        let outputs = try container.decodeIfPresent([StoredEntry].self, forKey: .outputs) ?? []
        guard (entries + outputs).allSatisfy({
            $0.path.hasPrefix("/") && $0.size >= 0 && $0.modified.isFinite && ($0.failures ?? 0) >= 0
        }) else {
            throw DecodingError.dataCorruptedError(forKey: .entries, in: container,
                                                   debugDescription: "Invalid ledger entry")
        }
        for stored in entries.suffix(Self.maxEntries) {
            let fingerprint = FileFingerprint(path: stored.path, size: stored.size, modified: stored.modified)
            let failures = min(stored.failures ?? 0, Self.maxAttempts)
            Self.insert(Entry(fingerprint: fingerprint, failures: failures, order: 0), into: &inputs, order: &nextOrder)
        }
        recordOutputs(outputs.suffix(Self.maxEntries).map {
            FileFingerprint(path: $0.path, size: $0.size, modified: $0.modified)
        })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(Self.stored(inputs), forKey: .entries)
        try container.encode(Self.stored(outputs), forKey: .outputs)
    }

    private static func stored(_ table: [String: Entry]) -> [StoredEntry] {
        sorted(table).map {
            StoredEntry(path: $0.fingerprint.path, size: $0.fingerprint.size, modified: $0.fingerprint.modified,
                        failures: $0.failures == 0 ? nil : $0.failures)
        }
    }
}
