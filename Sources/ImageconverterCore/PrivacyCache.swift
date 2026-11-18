import Foundation

/// Privacy findings per file, read once per file version (URL and `FileVersion`: identity, modification date and size) so adding images or
/// changing the pipeline never rescans an unchanged file. Scans run on the actor, never on the main actor.
public actor PrivacyCache {
    private struct Key: Hashable {
        let url: URL
        let version: FileVersion

        init(_ url: URL) {
            self.url = url
            version = FileVersion(url)
        }
    }

    private var entries: [Key: PrivacyFindings] = [:]
    /// How many files were scanned (for tests).
    public private(set) var scanCount = 0

    public init() {}

    public func findings(for url: URL) -> PrivacyFindings {
        versionedFindings(for: url).findings
    }

    /// The findings and the file version they were read from (taken before the scan: a file rewritten during it
    /// looks changed afterwards, never the reverse).
    public func versionedFindings(for url: URL) -> (findings: PrivacyFindings, version: FileVersion) {
        let key = Key(url)
        if let cached = entries[key] { return (cached, key.version) }
        let found = PrivacyScanner.scan(url)
        scanCount += 1
        entries[key] = found
        return (found, key.version)
    }

    public func removeAll() { entries = [:] }

    /// Forgets files that are no longer in the batch.
    public func retain(only urls: Set<URL>) {
        entries = entries.filter { urls.contains($0.key.url) }
    }
}
