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
    public static let maxBookmarkSize = FolderAccess.maxBookmarkSize

    public init(path: String = "", bookmark: Data? = nil, shadow: WatermarkShadow? = nil) {
        self.path = path
        self.bookmark = bookmark
        self.shadow = shadow
    }

    /// The watermark for the file at `url`, with a bookmark made now (while the app has access to it).
    public static func chosen(_ url: URL, shadow: WatermarkShadow? = nil,
                              bookmarker: (URL) -> Data? = FolderAccess.usableBookmark) -> ImageWatermark {
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
        // In the real sandbox only a security-scoped bookmark whose access started opens the file.
        if let bookmark, let resolved = FolderAccess.resolveFile(bookmark),
           resolved.isSecurityScoped || !Sandbox.isEnforced {
            let grant = FolderAccess.Grant([resolved.url])
            defer { grant.release() }
            if grant.givesAccess { return try body(resolved.url) }
        }
        let url = URL(fileURLWithPath: path)
        if bookmark != nil, !FileManager.default.isReadableFile(atPath: url.path) { return try body(nil) }
        return try body(url)
    }

    /// This watermark with its bookmark renewed, when the stored one is stale (the file moved or its volume
    /// changed) and resolves; nil when there is nothing to update.
    public func refreshed(resolver: (Data) -> FolderAccess.Resolved? = FolderAccess.resolveFile) -> ImageWatermark? {
        guard let bookmark, let resolved = resolver(bookmark), let renewed = resolved.refreshed,
              renewed != bookmark else { return nil }
        var copy = self
        copy.bookmark = renewed
        copy.path = resolved.url.path
        return copy
    }
}

extension Pipeline {
    /// The pipeline with every image watermark (also inside condition branches) passed through `transform`;
    /// nil when `transform` changed none of them.
    public func updatingImageWatermarks(_ transform: (ImageWatermark) -> ImageWatermark?) -> Pipeline? {
        var copy = self
        var changed = false
        /// True when `step` (or a step in its branches) changed.
        func update(_ step: inout PipelineStep) -> Bool {
            switch step.operation {
            case .watermark(var options):
                guard case .image(let watermark) = options.content, let new = transform(watermark) else { return false }
                options.content = .image(new)
                step.operation = .watermark(options)
                return true
            case .condition(var condition):
                var any = false
                for branch in [\ConditionalStep.then, \ConditionalStep.otherwise] {
                    for index in condition[keyPath: branch].indices {
                        guard case .step(var inner) = condition[keyPath: branch][index], update(&inner) else { continue }
                        condition[keyPath: branch][index] = .step(inner)
                        any = true
                    }
                }
                if any { step.operation = .condition(condition) }
                return any
            default:
                return false
            }
        }
        for index in copy.steps.indices where update(&copy.steps[index]) { changed = true }
        return changed ? copy : nil
    }
}
