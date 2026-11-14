import Foundation

/// Moves a file to the Trash. Injected so tests never touch the real Trash.
public typealias Trasher = @Sendable (URL) throws -> Void

/// Moves a file to the user's Trash.
public let systemTrash: Trasher = { url in
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
}

public enum FileCommitter {
    /// Prefix of the hidden temporary files written next to the destination.
    public static let tempPrefix = ".imageconverter-"

    /// Writes `data` next to its destination as a temporary file, then moves it into place, so a
    /// half-written file never appears under the final name. An existing file is only replaced
    /// when `plan.replacesSource` is set; otherwise an existing destination makes this fail.
    /// The original is trashed only after the new file is in place. If trashing fails, the new
    /// file stays and `.writeFailed("Converted, but couldn't move the original to the Trash: …")`
    /// is thrown. Every other failure removes the temp file and throws `.writeFailed`.
    public static func commit(_ data: Data, for plan: PlannedOutput, trash: Trasher = systemTrash) throws {
        guard !(plan.replacesSource && plan.trashesSource) else {
            throw ConversionError.writeFailed("Invalid output plan")
        }
        let files = FileManager.default
        let directory = plan.destination.deletingLastPathComponent()
        let temp = beginTemp(in: directory)
        defer { endTemp(temp) }

        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp, options: [.withoutOverwriting])
            if plan.replacesSource {
                _ = try files.replaceItemAt(plan.destination, withItemAt: temp)
            } else {
                try files.moveItem(at: temp, to: plan.destination)
            }
        } catch {
            try? files.removeItem(at: temp)
            throw ConversionError.writeFailed(error.localizedDescription)
        }

        if plan.trashesSource {
            do {
                try trash(plan.item.source)
            } catch {
                throw ConversionError.writeFailed(trashFailurePrefix + error.localizedDescription)
            }
        }
    }

    /// Starts the reason of a failure that happened after the new file was in place.
    static let trashFailurePrefix = "Converted, but couldn't move the original to the Trash: "

    // MARK: Temp files

    /// Temp files this process is writing right now, and every folder it has written to; a clean-up never
    /// removes a temp file that is still being written here.
    private static let state = TempState()

    /// A new temp file URL in `directory`, registered as in use until `endTemp`.
    static func beginTemp(in directory: URL) -> URL {
        let temp = directory.appendingPathComponent("\(tempPrefix)\(UUID().uuidString)\(tempSuffix)")
        state.begin(temp)
        return temp
    }

    static func endTemp(_ temp: URL) { state.end(temp) }

    static let tempSuffix = ".tmp"

    /// Temp files younger than this survive the clean-up after a cancel (they may belong to another process).
    public static let cancelCleanupAge: TimeInterval = 60

    /// True only for the exact pattern `.imageconverter-<UUID>.tmp`, with an uppercase UUID as
    /// `UUID().uuidString` writes it.
    public static func isTempFileName(_ name: String) -> Bool {
        guard name.hasPrefix(tempPrefix), name.hasSuffix(tempSuffix) else { return false }
        let middle = String(name.dropFirst(tempPrefix.count).dropLast(tempSuffix.count))
        return UUID(uuidString: middle)?.uuidString == middle
    }

    /// Every folder a commit has written to in this process (standardized), for the clean-up when the app quits.
    public static var writtenDirectories: [URL] { state.directories }

    /// Removes this app's temp files directly in `directories` (not in subfolders): only regular files (never
    /// folders or links) named exactly `.imageconverter-<UUID>.tmp`, older than `age` seconds, and not being
    /// written by this process right now. Called when a run is cancelled, when the app quits and, with an age
    /// of an hour, at the start of a run. The files are deleted, not "securely wiped": on SSDs and APFS
    /// (copy-on-write) overwriting a file doesn't reliably overwrite its old blocks, so wiping would promise
    /// something it can't do.
    public static func cleanUp(in directories: [URL], olderThan age: TimeInterval = 0, now: Date = Date()) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        for folder in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where isTempFileName(name) {
                let url = folder.appendingPathComponent(name)
                guard !state.isInUse(url), let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      age <= 0 || now.timeIntervalSince(modified) >= age else {
                    continue
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// Lock-protected bookkeeping for `FileCommitter`'s temp files.
private final class TempState: @unchecked Sendable {
    private let lock = NSLock()
    private var inUse = Set<String>()
    private var folders: [URL] = []
    private var folderPaths = Set<String>()

    func begin(_ temp: URL) {
        let folder = temp.deletingLastPathComponent().standardizedFileURL
        lock.lock()
        inUse.insert(temp.standardizedFileURL.path)
        if folderPaths.insert(folder.path).inserted { folders.append(folder) }
        lock.unlock()
    }

    func end(_ temp: URL) {
        lock.lock()
        inUse.remove(temp.standardizedFileURL.path)
        lock.unlock()
    }

    func isInUse(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inUse.contains(url.standardizedFileURL.path)
    }

    var directories: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return folders
    }
}
