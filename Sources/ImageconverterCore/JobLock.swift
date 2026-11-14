import Foundation

/// An advisory lock on one job (`flock` on `jobs/<id>.lock`), held while it runs. Another process (the command
/// line and the app) or another open of the same file can't take it, so a job never runs twice at once. The lock
/// goes away with the process, so a crash never leaves a job locked.
public final class JobLock: @unchecked Sendable {
    public static let busyMessage = "This job is already running."

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The lock, or nil when someone else holds it (or the file can't be opened). Never waits.
    public static func acquire(_ url: URL) -> JobLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return JobLock(descriptor: descriptor)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
