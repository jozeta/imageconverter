import Foundation

/// A folder chosen for an extra output: its path, and a bookmark so the sandboxed app (and its jobs) can open it
/// again after a relaunch. Pipelines, presets and jobs carry it; the path alone is used when there is none.
public struct VariantFolder: Codable, Equatable, Sendable {
    /// An absolute path; empty while no folder is chosen yet (the output can't run then).
    public var path: String
    /// An app-scoped security-scoped bookmark of the folder (a plain one outside the sandbox), made when chosen.
    public var bookmark: Data?

    /// Paths longer than this in an untrusted file make the destination unreadable.
    public static let maxPathLength = 4096

    public init(path: String = "", bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }

    /// The folder at `url`, with a bookmark made now (while the app has access to it).
    public static func chosen(_ url: URL, bookmarker: (URL) -> Data? = FolderAccess.usableBookmark) -> VariantFolder {
        VariantFolder(path: url.standardizedFileURL.path, bookmark: bookmarker(url))
    }

    public var isChosen: Bool { !path.isEmpty }

    /// The folder as a file URL (the stored path; `resolved` follows a moved folder).
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// The folder now: the bookmark's folder when it resolves, else the stored path.
    public func resolved(resolver: (Data) -> FolderAccess.Resolved? = FolderAccess.resolve) -> URL {
        if let bookmark, let found = resolver(bookmark) { return found.url }
        return url
    }

    private enum CodingKeys: String, CodingKey { case path, bookmark }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        guard Self.isUsablePath(text) else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: container,
                                                   debugDescription: "Not an absolute folder path")
        }
        path = text.isEmpty ? "" : URL(fileURLWithPath: text).standardizedFileURL.path
        let data = try? container.decodeIfPresent(Data.self, forKey: .bookmark)
        bookmark = data.flatMap { !$0.isEmpty && $0.count <= FolderAccess.maxBookmarkSize ? $0 : nil }
    }

    /// Empty (not chosen yet), or an absolute path without control characters and within the length limit.
    public static func isUsablePath(_ text: String) -> Bool {
        if text.isEmpty { return true }
        return text.hasPrefix("/") && text.utf8.count <= maxPathLength
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Where an extra output goes, when not beside the main output (`OutputVariant.destination` nil). Never "overwrite
/// the originals": an extra output is always a new file, whatever its folder.
public enum OutputDestination: Codable, Equatable, Sendable {
    /// A chosen folder, flat (or under the output's own subfolder).
    case folder(VariantFolder)
    /// The original's own folder.
    case sameFolder
    /// A folder (template: rename tokens, `/` between folders) inside the original's folder.
    case subfolder(String)

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case folder, sameFolder, subfolder
    }

    public var kind: Kind {
        switch self {
        case .folder: return .folder
        case .sameFolder: return .sameFolder
        case .subfolder: return .subfolder
        }
    }

    /// Writes next to the originals (in their folders or below them).
    public var isBesideOriginals: Bool { kind != .folder }

    /// The subfolder template of `.subfolder` when it names a folder.
    public var subfolderTemplate: String? {
        guard case .subfolder(let template) = self, !SubfolderTemplate.isBlank(template) else { return nil }
        return template
    }

    /// "Same folder as original", "Subfolder “thumbs” next to original", "Folder “Web”".
    public var summary: String {
        switch self {
        case .folder(let folder):
            return folder.isChosen ? "folder \u{201C}\(folder.url.lastPathComponent)\u{201D}" : "no folder chosen"
        case .sameFolder: return "next to the original"
        case .subfolder(let template): return "\u{201C}\(template)\u{201D} next to the original"
        }
    }

    /// Why this destination can't run yet; nil when it can.
    public var problem: String? {
        switch self {
        case .folder(let folder): return folder.isChosen ? nil : OutputVariant.noFolderProblem
        case .sameFolder: return nil
        case .subfolder(let template):
            return SubfolderTemplate.isBlank(template) ? OutputVariant.noSubfolderProblem : nil
        }
    }

    // MARK: Coding: {"kind":"folder","path":…,"bookmark":…}, {"kind":"sameFolder"}, {"kind":"subfolder","name":…}

    private enum CodingKeys: String, CodingKey { case kind, name }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown kind (a newer version) fails the output: it is left out with a note, never redirected.
        switch try container.decode(Kind.self, forKey: .kind) {
        case .folder: self = .folder(try VariantFolder(from: decoder))
        case .sameFolder: self = .sameFolder
        case .subfolder:
            let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            self = .subfolder(String(name.prefix(RenameTemplate.maxLength)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .folder(let folder): try folder.encode(to: encoder)
        case .sameFolder: break
        case .subfolder(let template): try container.encode(template, forKey: .name)
        }
    }
}

extension OutputVariant {
    /// The output "+" adds: a copy of the main output's settings (format, compression, quality and the rest; the
    /// same size), named "Output N" after the main output and the ones already there, with a suffix no other output
    /// uses (`_out2`, `_out3`, …), saved beside the main output until another Save to is chosen.
    public static func added(after existing: [OutputVariant], main: OutputSettings) -> OutputVariant {
        let names = Set(existing.map { $0.name.lowercased() })
        let suffixes = Set(existing.map { $0.cleanSuffix.lowercased() })
        let first = existing.count + 2
        let number = (first...(first + maxCount + 1)).first {
            !names.contains("output \($0)") && !suffixes.contains("_out\($0)")
        } ?? first
        return OutputVariant(name: "Output \(number)", settings: main, resize: nil, nameSuffix: "_out\(number)")
    }

    public static let noFolderProblem = "Choose a folder for this output"
    public static let noSubfolderProblem = "Name the subfolder for this output"

    /// The folder this output starts from for one item: the primary output's folder (no destination), the chosen
    /// folder (`folders` maps its path to where it is now, e.g. a moved folder its bookmark found), or the
    /// original's own folder. Its subfolders (`.subfolder`, then `subfolder`) are added by the planner.
    func baseFolder(primary: URL, source: URL, folders: [String: URL]) -> URL {
        switch destination {
        case nil: return primary.deletingLastPathComponent()
        case .folder(let folder)?: return folders[folder.path] ?? folder.url
        case .sameFolder?, .subfolder?: return source.deletingLastPathComponent()
        }
    }
}

/// The chosen folders of a batch's extra outputs, resolved once per run: where each is now (its bookmark followed),
/// with access started on the resolved URLs for as long as this is kept (the run's lifetime).
final class VariantFolderAccess: @unchecked Sendable {
    /// Stored path → the folder now.
    let folders: [String: URL]
    private let grant: FolderAccess.Grant

    init(_ variants: [OutputVariant], resolver: (Data) -> FolderAccess.Resolved? = FolderAccess.resolve) {
        var folders: [String: URL] = [:]
        for variant in variants {
            guard case .folder(let folder)? = variant.destination, folder.isChosen, folders[folder.path] == nil
            else { continue }
            folders[folder.path] = folder.resolved(resolver: resolver)
        }
        self.folders = folders
        grant = FolderAccess.Grant(Array(folders.values))
    }

    static let none = VariantFolderAccess([])
}
