import Foundation

/// An image watermark (any format ImageIO reads, or SVG): its path, and a bookmark of the file so the sandboxed
/// app can open it again after a relaunch (presets and templates carry it; older files have none).
public struct ImageWatermark: Codable, Equatable, Sendable {
    public var path: String
    /// An app-scoped security-scoped bookmark of the file at `path` (a plain one outside the sandbox), made when
    /// the image is chosen. Nil in older pipelines: the path alone is used.
    public var bookmark: Data?
    /// Nil: no shadow.
    public var shadow: WatermarkShadow?

    /// A bookmark is a few KB; anything larger in an untrusted file is dropped.
    public static let maxBookmarkSize = 64 * 1024

    public init(path: String = "", bookmark: Data? = nil, shadow: WatermarkShadow? = nil) {
        self.path = path
        self.bookmark = bookmark
        self.shadow = shadow
    }

    /// The watermark for the file at `url`, with a bookmark made now (while the app has access to it).
    public static func chosen(_ url: URL, shadow: WatermarkShadow? = nil,
                              bookmarker: (URL) -> Data? = FolderAccess.bookmark) -> ImageWatermark {
        ImageWatermark(path: url.path, bookmark: bookmarker(url), shadow: shadow)
    }

    private enum CodingKeys: String, CodingKey { case path, bookmark, shadow }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        let data = try? container.decodeIfPresent(Data.self, forKey: .bookmark)
        bookmark = data.flatMap { $0.count <= Self.maxBookmarkSize && !$0.isEmpty ? $0 : nil }
        shadow = try container.decodeIfPresent(WatermarkShadow.self, forKey: .shadow)
    }

    /// Runs `body` with the file to read: the bookmark's file (access started for the call) when it resolves,
    /// else the plain path. Nil when there is a bookmark that doesn't resolve and the path can't be read either
    /// (moved, deleted, or no longer allowed in the sandbox): the user has to choose the image again.
    public func withFile<T>(_ body: (URL?) throws -> T) rethrows -> T {
        if let bookmark, let resolved = FolderAccess.resolveFile(bookmark) {
            return try FolderAccess.withAccess([resolved.url]) { try body(resolved.url) }
        }
        let url = URL(fileURLWithPath: path)
        if bookmark != nil, !FileManager.default.isReadableFile(atPath: url.path) { return try body(nil) }
        return try body(url)
    }
}
