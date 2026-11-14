import CoreServices
import Foundation

/// A file's size, modification date and whether it can be opened, as seen at one moment.
public struct FileSnapshot: Equatable, Sendable {
    public var size: Int
    public var modified: Date
    public var readable: Bool

    public init(size: Int, modified: Date, readable: Bool) {
        self.size = size
        self.modified = modified
        self.readable = readable
    }

    /// Nil when `url` isn't a regular file (gone, a folder, a link).
    public static func take(_ url: URL) -> FileSnapshot? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor >= 0 { close(descriptor) }
        return FileSnapshot(size: Int(info.st_size), modified: modified, readable: descriptor >= 0)
    }
}

/// Decides when a file that changed is ready: its size and modification date stayed the same for `stableFor`
/// seconds and it can be opened (a file still being copied keeps waiting). Pure: the clock and the snapshots
/// are passed in.
public struct ReadinessTracker: Sendable {
    public let stableFor: TimeInterval
    private var pending: [URL: (snapshot: FileSnapshot?, since: Date)] = [:]

    public init(stableFor: TimeInterval = 2) {
        self.stableFor = stableFor
    }

    public var isEmpty: Bool { pending.isEmpty }
    public var pendingFiles: Set<URL> { Set(pending.keys) }

    /// A change was seen for `url`. A file already waiting keeps its timer: the next poll sees whether it changed.
    public mutating func note(_ url: URL, now: Date) {
        if pending[url] == nil { pending[url] = (nil, now) }
    }

    /// Re-checks every waiting file and returns the ones that became ready (sorted by path); those, and
    /// files that disappeared, stop being tracked.
    public mutating func poll(now: Date, snapshot: (URL) -> FileSnapshot?) -> [URL] {
        var ready: [URL] = []
        for (url, state) in pending {
            guard let current = snapshot(url) else {
                pending[url] = nil
                continue
            }
            if current != state.snapshot {
                pending[url] = (current, now)
            } else if now.timeIntervalSince(state.since) >= stableFor, current.readable {
                ready.append(url)
                pending[url] = nil
            }
        }
        return ready.sorted { $0.path < $1.path }
    }
}

/// Which changed paths are worth watching: inside a watched folder (directly, unless recursive), not hidden,
/// not one of our temp files, and not inside an excluded (output) folder.
public struct WatchFilter: Sendable {
    public let roots: [String]
    public let recursive: Bool
    public let excluded: [String]

    public init(folders: [URL], recursive: Bool, excluded: [URL] = []) {
        roots = folders.map(Self.canonicalPath)
        self.recursive = recursive
        self.excluded = excluded.map(Self.canonicalPath)
    }

    /// The real path (FSEvents reports `/private/var/...` for `/var/...`); the path itself if it doesn't exist.
    public static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func accepts(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(FileCommitter.tempPrefix) && name.hasSuffix(".tmp") { return false }
        if isExcluded(path) { return false }
        return roots.contains { root in
            guard Self.isInside(path, root) else { return false }
            let components = String(path.dropFirst(root.count)).split(separator: "/")
            // Hidden files and anything inside a hidden folder (.git, .Trashes, our temp files) are ignored.
            guard !components.contains(where: { $0.hasPrefix(".") }) else { return false }
            return recursive || components.count == 1
        }
    }

    /// True for an output folder and everything in it.
    public func isExcluded(_ path: String) -> Bool {
        excluded.contains { Self.isInside(path, $0) || Self.same(path, $0) }
    }

    /// macOS volumes are usually case-insensitive: compare paths that way (at worst a file too many is checked).
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.count > prefix.count && path.lowercased().hasPrefix(prefix.lowercased())
    }

    static func same(_ lhs: String, _ rhs: String) -> Bool { lhs.lowercased() == rhs.lowercased() }
}

/// Watches folders with FSEvents (file-level events, 1 s latency) and reports files once they are ready
/// (see `ReadinessTracker`). Only changes after `start()` are reported; run the job once to catch up.
/// `onReady` is called on the watcher's own serial queue. Call `stop()` when done (deinit also stops it).
public final class FolderWatcher: @unchecked Sendable {
    public let filter: WatchFilter
    private let latency: TimeInterval
    private let pollInterval: TimeInterval
    private let clock: @Sendable () -> Date
    private let onReady: @Sendable ([URL]) -> Void
    private let queue = DispatchQueue(label: "imageconverter.folder-watcher")
    private let queueKey = DispatchSpecificKey<Void>()
    // Everything below is only touched on `queue`.
    private var tracker: ReadinessTracker
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    /// The stream's context points here (not at self): the box outlives no stream, and holds self weakly.
    private let box = WeakBox()

    private final class WeakBox {
        weak var watcher: FolderWatcher?
    }

    public init(folders: [URL], recursive: Bool, excluded: [URL] = [], latency: TimeInterval = 1,
                stableFor: TimeInterval = 2, pollInterval: TimeInterval = 0.5,
                clock: @escaping @Sendable () -> Date = { Date() },
                onReady: @escaping @Sendable ([URL]) -> Void) {
        filter = WatchFilter(folders: folders, recursive: recursive, excluded: excluded)
        self.latency = latency
        self.pollInterval = pollInterval
        self.clock = clock
        self.onReady = onReady
        tracker = ReadinessTracker(stableFor: stableFor)
        queue.setSpecific(key: queueKey, value: ())
        box.watcher = self
    }

    deinit {
        onQueue { stopOnQueue() }
    }

    /// Starts watching; false when the stream couldn't be created or started. Calling it again is harmless.
    @discardableResult
    public func start() -> Bool {
        onQueue { startOnQueue() }
    }

    public func stop() {
        onQueue { stopOnQueue() }
    }

    /// Files seen but not yet ready (for tests and the UI).
    public var pendingFiles: Set<URL> {
        onQueue { tracker.pendingFiles }
    }

    private func onQueue<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? work() : queue.sync(execute: work)
    }

    private func startOnQueue() -> Bool {
        if stream != nil { return true }
        guard !filter.roots.isEmpty else { return false }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let box = Unmanaged<WeakBox>.fromOpaque(info).takeUnretainedValue()
            guard let watcher = box.watcher,
                  let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let flags = (0..<count).map { eventFlags[$0] }
            watcher.handle(paths: list, flags: flags)
        }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, filter.roots as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                                flags) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    private func stopOnQueue() {
        if let stream {
            // Stopped and invalidated now (no callback runs after this), but released later: this may run inside the
            // stream's own callout (stop() or the last release from onReady), where releasing it is not safe.
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            let released = StreamBox(stream: stream)
            queue.async { FSEventStreamRelease(released.stream) }
        }
        stream = nil
        timer?.cancel()
        timer = nil
        // A later start() only reports changes from then on: don't keep files nobody polls.
        tracker = ReadinessTracker(stableFor: tracker.stableFor)
    }

    private struct StreamBox: @unchecked Sendable {
        let stream: FSEventStreamRef
    }

    /// Runs on `queue` (the stream's dispatch queue).
    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let now = clock()
        for (path, flag) in zip(paths, flags) {
            switch Self.action(for: flag) {
            case .scan: scan(path, now: now)
            case .ignore: break
            case .file where filter.accepts(path):
                tracker.note(URL(fileURLWithPath: path), now: now)
            case .file: break
            }
        }
        startPollingIfNeeded()
    }

    enum EventAction: Equatable { case file, scan, ignore }

    /// Events were dropped, or a folder was created or moved in: scan it. Other folder events (tags, permissions,
    /// removal) say nothing about new files. Everything else is about one file.
    static func action(for flags: FSEventStreamEventFlags) -> EventAction {
        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        if has(kFSEventStreamEventFlagMustScanSubDirs) { return .scan }
        guard has(kFSEventStreamEventFlagItemIsDir) else { return .file }
        return has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRenamed) ? .scan : .ignore
    }

    private func scan(_ path: String, now: Date) {
        guard !filter.isExcluded(path) else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let options: FileManager.DirectoryEnumerationOptions = filter.recursive
            ? [.skipsHiddenFiles, .skipsPackageDescendants]
            : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: options) else { return }
        for case let url as URL in files where filter.accepts(url.path) {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                tracker.note(url, now: now)
            }
        }
    }

    private func startPollingIfNeeded() {
        guard timer == nil, !tracker.isEmpty else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    private func poll() {
        let ready = tracker.poll(now: clock(), snapshot: FileSnapshot.take)
        if tracker.isEmpty {
            timer?.cancel()
            timer = nil
        }
        if !ready.isEmpty { onReady(ready) }
    }
}
