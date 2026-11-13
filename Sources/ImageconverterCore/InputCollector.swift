import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One image file to convert, and where it sat in the dropped folder structure.
public struct InputItem: Hashable, Sendable {
    public let source: URL
    /// `""` for a loose file; for a file found in a dropped folder `Trip`, the path from the
    /// dropped folder's parent, e.g. `"Trip"` or `"Trip/day2"`.
    public let relativeDirectory: String

    public init(source: URL, relativeDirectory: String) {
        self.source = source
        self.relativeDirectory = relativeDirectory
    }
}

/// Turns dropped files and folders into a flat, sorted, de-duplicated list of image files.
public enum InputCollector {
    public static func collect(_ urls: [URL]) -> [InputItem] {
        let fileManager = FileManager.default
        var found: [URL: InputItem] = [:]

        for dropped in urls {
            let root = dropped.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }

            if !isDirectory.boolValue {
                add(InputItem(source: root, relativeDirectory: ""), to: &found)
                continue
            }

            let parentPath = root.deletingLastPathComponent().path
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    continue
                }
                let file = url.resolvingSymlinksInPath()
                let directory = file.deletingLastPathComponent().path
                let relative = directory.hasPrefix(parentPath + "/")
                    ? String(directory.dropFirst(parentPath.count + 1))
                    : root.lastPathComponent
                add(InputItem(source: file, relativeDirectory: relative), to: &found)
            }
        }
        return found.values.sorted { $0.source.path < $1.source.path }
    }

    private static func add(_ item: InputItem, to found: inout [URL: InputItem]) {
        guard isImage(item.source), found[item.source] == nil else { return }
        found[item.source] = item
    }

    private static func isImage(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        guard type.conforms(to: .image) else { return false }
        return readableTypes.contains(type.identifier)
            || type.supertypes.contains { readableTypes.contains($0.identifier) }
    }

    /// Type identifiers ImageIO can decode (so `.svg`, which is an image type but not decodable, is out).
    private static let readableTypes: Set<String> =
        Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
}
