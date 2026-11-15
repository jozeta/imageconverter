import Foundation

/// Unpacking an update zip: `ditto` under a watchdog, and the check that what it wrote is what the listing named.
extension UpdatePackage {
    /// Unpacks `zip` with `ditto -x -k --noqtn` into `folder` (created here; it must not exist) under the watchdog
    /// (`runWatched`), then checks the unpacked size again. Any failure deletes the folder.
    public static func unpack(_ zip: URL, into folder: URL, limits: Limits = .standard,
                              freeSpace: (URL) -> Int64? = availableCapacity) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            throw UpdateError.badPackage("its unpack folder could not be created")
        }
        do {
            let watch = Watch(maxBytes: limits.maxUncompressedBytes + limits.unpackMargin, minFreeBytes: limits.minFreeBytes,
                              interval: limits.pollInterval)
            let status = try runWatched("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip.path, folder.path], folder: folder,
                                        watch: watch, freeSpace: freeSpace)
            guard status == 0 else { throw UpdateError.badPackage("the zip could not be unpacked") }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// What `runWatched` enforces.
    public struct Watch: Equatable, Sendable {
        public var maxBytes: Int64
        public var minFreeBytes: Int64
        public var interval: TimeInterval

        public init(maxBytes: Int64, minFreeBytes: Int64, interval: TimeInterval) {
            self.maxBytes = maxBytes
            self.minFreeBytes = minFreeBytes
            self.interval = interval
        }
    }

    /// Runs a tool that writes into `folder` and stops it (SIGTERM, then SIGKILL after 2 s) when the folder's allocated
    /// size (resource forks included) or the volume's loss of free space since the start is more than `watch.maxBytes`,
    /// or the volume has less than `watch.minFreeBytes` free. Checked first, then every `watch.interval` seconds, then
    /// once more at the end. Returns the tool's exit status.
    public static func runWatched(_ path: String, _ arguments: [String], folder: URL, watch: Watch,
                                  freeSpace: (URL) -> Int64?) throws -> Int32 {
        let maxBytes = watch.maxBytes, minFreeBytes = watch.minFreeBytes, interval = watch.interval
        let tooLarge = UpdateError.badPackage("it is too large when unpacked")
        let lowSpace = UpdateError.badPackage("there isn't enough free disk space to unpack it")
        let startFree = freeSpace(folder)
        if let startFree, startFree < minFreeBytes { throw lowSpace }
        /// Space used: what the folder holds, or what the volume lost since the start, whichever is more.
        func used() -> (bytes: Int64, free: Int64?) {
            let free = freeSpace(folder)
            let lost = startFree.flatMap { start in free.map { start - $0 } } ?? 0
            return (max(bytesWritten(in: folder), lost), free)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.badPackage("\(URL(fileURLWithPath: path).lastPathComponent) could not run") }
        var failure: UpdateError?
        while process.isRunning {
            Thread.sleep(forTimeInterval: interval)
            let now = used()
            if let free = now.free, free < minFreeBytes {
                failure = lowSpace
            } else if now.bytes > maxBytes {
                failure = tooLarge
            }
            if failure != nil {
                stop(process)
                break
            }
        }
        process.waitUntilExit()
        if let failure { throw failure }
        if used().bytes > maxBytes { throw tooLarge }
        return process.terminationStatus
    }

    /// SIGTERM, then SIGKILL if it is still running after 2 seconds.
    static func stop(_ process: Process) {
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Why the unpacked tree isn't what the listing said, or nil: everything must be inside the one
    /// `imageconverter.app`, and every file or link must be a listed entry (every folder listed or above one), compared
    /// the way APFS compares names. (`._` AppleDouble entries are merged into their files by ditto, so they may be absent.)
    public static func unpackedTreeProblem(in folder: URL, listing: Listing) -> String? {
        var listed = Set<String>()
        var ancestors = Set<String>()
        for name in listing.names {
            let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
            listed.insert(folded(trimmed))
            var components = trimmed.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                ancestors.insert(folded(components.joined(separator: "/")))
            }
        }
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else {
            return "it could not be read after unpacking"
        }
        while let relative = enumerator.nextObject() as? String {
            let key = folded(relative)
            let isFolder = enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            guard listed.contains(key) || (isFolder && ancestors.contains(key)) else {
                return "it unpacked \u{201C}\(relative)\u{201D}, which its listing doesn't name"
            }
        }
        return nil
    }

    /// The bytes allocated to the regular files under `folder`, resource forks included (links not followed).
    static func bytesWritten(in folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(max(values.totalFileAllocatedSize ?? 0, values.fileSize ?? 0))
        }
        return total
    }

    /// Free space for important data on the volume holding `folder` (or its parent while it doesn't exist).
    public static func availableCapacity(_ folder: URL) -> Int64? {
        let existing = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        return (try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
