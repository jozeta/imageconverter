import Foundation

/// One failure line from the error log.
public struct ErrorLogEntry: Equatable, Sendable {
    public let date: Date
    public let path: String
    public let reason: String
}

/// A plain-text log of failures: one line per failed file (`ISO time TAB path TAB reason`), never image data.
/// Rotated at `maxBytes` (1 MB): `errors.log` becomes `errors.1.log`, and so on; `keep` rotated files are kept.
public final class ErrorLog: @unchecked Sendable {
    public static let maxBytes = 1_000_000
    public static let keep = 3

    private let directory: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(directory: URL = ErrorLog.defaultDirectory, maxBytes: Int = ErrorLog.maxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("imageconverter", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    public var logURL: URL { directory.appendingPathComponent("errors.log", isDirectory: false) }

    private func rotatedURL(_ number: Int) -> URL {
        directory.appendingPathComponent("errors.\(number).log", isDirectory: false)
    }

    /// Appends one line. Path and reason are single-lined (no control, bidi or separator characters).
    public func record(path: String, reason: String, at date: Date = Date()) {
        record([(path, reason)], at: date)
    }

    public func record(_ failures: [(path: String, reason: String)], at date: Date = Date()) {
        guard !failures.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: date)
        let lines = failures.map { "\(stamp)\t\(ReportExporter.printable($0.path))\t\(ReportExporter.printable($0.reason))\n" }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for line in lines { append(Data(line.utf8)) }
    }

    private func append(_ line: Data) {
        let fileManager = FileManager.default
        let size = ((try? fileManager.attributesOfItem(atPath: logURL.path))?[.size] as? Int) ?? 0
        if size > 0, size + line.count > maxBytes { rotate() }
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private func rotate() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: rotatedURL(Self.keep))
        for number in stride(from: Self.keep - 1, through: 1, by: -1) {
            try? fileManager.moveItem(at: rotatedURL(number), to: rotatedURL(number + 1))
        }
        try? fileManager.moveItem(at: logURL, to: rotatedURL(1))
    }

    /// The newest `limit` entries, newest first, reading older files when the current one has too few.
    /// Files are read with the hardened reader; malformed lines are skipped.
    public func recent(limit: Int) -> [ErrorLogEntry] {
        guard limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var result: [ErrorLogEntry] = []
        let files = [logURL] + (1...Self.keep).map(rotatedURL)
        for file in files where result.count < limit {
            guard let data = try? StoredFile.readData(file, maxSize: max(maxBytes, StoredFile.maxFileSize) + 4096),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let dates = ISO8601DateFormatter()
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let date = dates.date(from: String(parts[0])) else { continue }
                result.append(ErrorLogEntry(date: date, path: String(parts[1]), reason: String(parts[2])))
                if result.count == limit { break }
            }
        }
        return result
    }

    /// Deletes the log and its rotated files.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for url in [logURL] + (1...Self.keep).map(rotatedURL) { try? FileManager.default.removeItem(at: url) }
    }
}
