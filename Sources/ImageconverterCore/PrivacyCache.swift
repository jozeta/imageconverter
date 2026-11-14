import Foundation

/// Privacy findings per file, read once per file version (URL, modification date and size) so adding images or
/// changing the pipeline never rescans an unchanged file. Scans run on the actor, never on the main actor.
public actor PrivacyCache {
    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        let size: Int?

        init(_ url: URL) {
            // A fresh URL: a URL caches its resource values, which would hide a rewritten file.
            let values = try? URL(fileURLWithPath: url.path)
                .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            self.url = url
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    private var entries: [Key: PrivacyFindings] = [:]
    /// How many files were scanned (for tests).
    public private(set) var scanCount = 0

    public init() {}

    public func findings(for url: URL) -> PrivacyFindings {
        let key = Key(url)
        if let cached = entries[key] { return cached }
        let found = PrivacyScanner.scan(url)
        scanCount += 1
        entries[key] = found
        return found
    }

    public func removeAll() { entries = [:] }

    /// Forgets files that are no longer in the batch.
    public func retain(only urls: Set<URL>) {
        entries = entries.filter { urls.contains($0.key.url) }
    }
}
