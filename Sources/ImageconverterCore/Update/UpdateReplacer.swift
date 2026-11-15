import Foundation

/// The file operations replacing the app needs, injected so tests run on temp folders with a fake Trash.
public protocol UpdateFileOperations {
    /// Moves `url` to the Trash; returns where it went (nil when the system doesn't say).
    func trash(_ url: URL) throws -> URL?
    func move(_ source: URL, to destination: URL) throws
}

/// The real operations: `FileManager.trashItem` and `moveItem`.
public struct SystemUpdateFileOperations: UpdateFileOperations {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    public func move(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

/// Swaps the installed app for the checked new one: the old app goes to the Trash, the new one is moved to the old
/// one's path (same name). A failure before the old app is trashed changes nothing; a failure after it moves the
/// old app back from the Trash.
public enum UpdateReplacer {
    public static func replace(_ installed: URL, with new: URL,
                               using operations: UpdateFileOperations = SystemUpdateFileOperations()) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: new.path) else { throw UpdateError.installFailed("the new app is missing.") }
        guard files.fileExists(atPath: installed.path) else { throw UpdateError.installFailed("the installed app was not found.") }
        let trashed: URL?
        do {
            trashed = try operations.trash(installed)
        } catch {
            throw UpdateError.installFailed("the current app could not be moved to the Trash (\(error.localizedDescription)).")
        }
        do {
            try operations.move(new, to: installed)
        } catch {
            let moveError = error.localizedDescription
            guard let trashed else {
                throw UpdateError.installFailed("the new app could not be moved into place (\(moveError)). "
                    + "The current app is in the Trash.")
            }
            do {
                try operations.move(trashed, to: installed)
            } catch {
                throw UpdateError.installFailed("the new app could not be moved into place (\(moveError)), and the current "
                    + "app could not be put back. It is in the Trash: \(trashed.path)")
            }
            throw UpdateError.installFailed("the new app could not be moved into place (\(moveError)). "
                + "The current app was restored.")
        }
    }
}
