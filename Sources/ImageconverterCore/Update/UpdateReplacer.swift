import Foundation

/// The file operations replacing the app needs, injected so tests run on temp folders with failures at every step.
public protocol UpdateFileOperations {
    func copy(_ source: URL, to destination: URL) throws
    /// A rename inside one folder.
    func move(_ source: URL, to destination: URL) throws
    func trash(_ url: URL) throws
    func remove(_ url: URL) throws
}

/// The real operations (`FileManager`).
public struct SystemUpdateFileOperations: UpdateFileOperations {
    public init() {}

    public func copy(_ source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func move(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Swaps the installed app for the checked new one without leaving the folder that holds it (the sandboxed app can
/// write there with its folder grant, but can't reach the Trash to bring anything back):
/// 1. `stage`: copy the verified app into that folder as a hidden sibling `.imageconverter-update-<uuid>.app` (also
///    works across volumes) and check the copy again (signature, version, links); any failure removes the copy and
///    leaves the installed app untouched.
/// 2. `swap`: rename the old app to `.imageconverter-old-<uuid>.app`, rename the copy to the app's name (on failure
///    the old app is renamed back), and only then move the old app to the Trash (or delete it; if both fail it stays
///    under its hidden name and a note says so).
/// After any failure either the old app or the new one is at the app's path.
public enum UpdateReplacer {
    public static let stagingPrefix = ".imageconverter-update-"
    public static let oldPrefix = ".imageconverter-old-"

    /// Copies `verified` beside `installed` and runs `verify` on the copy; returns the staged copy.
    public static func stage(_ verified: URL, beside installed: URL, using operations: UpdateFileOperations = SystemUpdateFileOperations(),
                             verify: (URL) throws -> Void) throws -> URL {
        let files = FileManager.default
        guard files.fileExists(atPath: verified.path) else { throw UpdateError.installFailed("the new app is missing.") }
        guard files.fileExists(atPath: installed.path) else { throw UpdateError.installFailed("the installed app was not found.") }
        let staged = sibling(of: installed, prefix: stagingPrefix)
        do {
            try operations.copy(verified, to: staged)
        } catch {
            discard(staged, using: operations)
            throw UpdateError.installFailed("the new app could not be copied next to the current one (\(error.localizedDescription)).")
        }
        do {
            try verify(staged)
        } catch {
            discard(staged, using: operations)
            throw error
        }
        return staged
    }

    /// Puts `staged` in place of `installed`. Returns a note when the old version could not be removed.
    public static func swap(_ installed: URL, with staged: URL,
                            using operations: UpdateFileOperations = SystemUpdateFileOperations()) throws -> String? {
        let old = sibling(of: installed, prefix: oldPrefix)
        do {
            try operations.move(installed, to: old)
        } catch {
            discard(staged, using: operations)
            throw UpdateError.installFailed("the current app could not be moved aside (\(error.localizedDescription)).")
        }
        do {
            try operations.move(staged, to: installed)
        } catch {
            let moveError = error.localizedDescription
            do {
                try operations.move(old, to: installed)
            } catch {
                throw UpdateError.installFailed("the new app could not be moved into place (\(moveError)), and the current app "
                    + "could not be put back. It is at \(old.path); rename it to \(installed.lastPathComponent).")
            }
            discard(staged, using: operations)
            throw UpdateError.installFailed("the new app could not be moved into place (\(moveError)). The current app was restored.")
        }
        if (try? operations.trash(old)) != nil { return nil }
        if (try? operations.remove(old)) != nil { return nil }
        return "The previous version could not be moved to the Trash; it is still at \(old.path)."
    }

    /// Removes hidden `.imageconverter-update-*.app` / `.imageconverter-old-*.app` siblings an interrupted install left
    /// next to `installed` (best effort).
    public static func removeLeftovers(beside installed: URL, using operations: UpdateFileOperations = SystemUpdateFileOperations()) {
        let folder = installed.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where (name.hasPrefix(stagingPrefix) || name.hasPrefix(oldPrefix)) && name.hasSuffix(".app") {
            try? operations.remove(folder.appendingPathComponent(name))
        }
    }

    /// Removes a staged copy (best effort).
    public static func discard(_ staged: URL, using operations: UpdateFileOperations = SystemUpdateFileOperations()) {
        guard FileManager.default.fileExists(atPath: staged.path) else { return }
        try? operations.remove(staged)
    }

    private static func sibling(of installed: URL, prefix: String) -> URL {
        installed.deletingLastPathComponent().appendingPathComponent(prefix + UUID().uuidString + ".app", isDirectory: true)
    }
}
