import Darwin
import Foundation

/// How the batch decides that two URLs are the same file. A file that exists is identified by its volume and
/// inode, so a path through a symlinked folder, a hard link or another spelling is still the same file. Anything
/// else (a planned destination that doesn't exist yet) is compared by path: symlinks in the existing part
/// resolved, and lower-cased only on a volume that ignores case (the macOS default); a case-sensitive volume
/// compares exactly, so `A.jpg` and `a.jpg` there stay two files.
public enum FileIdentity {
    /// The identity of the file at `url`: `"inode:<device>:<inode>"` when it exists, else `pathKey(url)`.
    public static func key(_ url: URL) -> String {
        var info = stat()
        if stat(url.path, &info) == 0 { return "inode:\(info.st_dev):\(info.st_ino)" }
        return pathKey(url)
    }

    /// The path as the file system compares it (see the type). `caseSensitive` overrides the volume lookup (tests).
    public static func pathKey(_ url: URL, caseSensitive: Bool? = nil) -> String {
        let resolved = resolved(url.standardizedFileURL)
        let sensitive = caseSensitive ?? isCaseSensitive(resolved.deletingLastPathComponent())
        return sensitive ? resolved.path : resolved.path.lowercased()
    }

    /// Symlinks resolved in the part of the path that exists (a missing last component is kept as written).
    static func resolved(_ url: URL) -> URL {
        if FileManager.default.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath() }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, parent.path != "/" else { return url }
        return resolved(parent).appendingPathComponent(url.lastPathComponent)
    }

    private static let cache = CaseCache()

    /// Whether the volume holding `directory` (or its nearest existing ancestor) tells case apart. Unknown counts
    /// as case-insensitive, the cautious answer for collisions.
    static func isCaseSensitive(_ directory: URL) -> Bool {
        var folder = directory
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" {
            folder = folder.deletingLastPathComponent()
        }
        if let known = cache.value(for: folder.path) { return known }
        let value = (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        cache.set(value, for: folder.path)
        return value
    }
}

/// Folder path → case sensitivity of its volume, lock-protected (planning runs off the main thread).
private final class CaseCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func value(for path: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return values[path]
    }

    func set(_ value: Bool, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        if values.count > 10_000 { values.removeAll() }
        values[path] = value
    }
}
