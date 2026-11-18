import Foundation

/// One version of a file's content, cheap to read: its identity (`FileIdentity.key`: volume and inode, else the
/// path), modification date and size. A file rewritten in place (Overwrite originals) gets a new version, so
/// anything keyed by it (the app's privacy findings, size estimate and metadata panel) reads the file again.
public struct FileVersion: Hashable, Sendable, CustomStringConvertible {
    public let identity: String
    public let modified: Date?
    public let size: Int?

    public init(identity: String, modified: Date?, size: Int?) {
        self.identity = identity
        self.modified = modified
        self.size = size
    }

    /// The version on disk now. A fresh URL: a URL caches its resource values, which would hide a rewritten file.
    public init(_ url: URL) {
        let values = try? URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        self.init(identity: FileIdentity.key(url), modified: values?.contentModificationDate, size: values?.fileSize)
    }

    public var description: String {
        "\(identity)|\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(size ?? -1)"
    }

    /// The files in `known` whose version on disk is no longer the one recorded (rewritten, replaced or gone).
    /// Reads every file's attributes: call it off the main actor.
    public static func changed(_ known: [URL: FileVersion]) -> [URL] {
        known.compactMap { url, version in FileVersion(url) == version ? nil : url }
    }
}
