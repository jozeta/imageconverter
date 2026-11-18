import Foundation

/// A folder chosen for an extra output: its path, and a bookmark so the sandboxed app (and its jobs) can open it
/// again after a relaunch. Pipelines, presets and jobs carry it; the path alone is used when there is none.
public struct VariantFolder: Codable, Hashable, Sendable {
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

    /// The folder as a file URL (the stored path; `resolution` follows a moved folder).
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Where the folder is, and whether this app may trust it without asking again.
    public enum Resolution: Equatable, Sendable {
        /// Opened through this app's own security-scoped bookmark (or, outside the sandbox, a bookmark that still
        /// names the stored folder): the folder now (a moved folder followed) and a renewed bookmark when stale.
        case confirmed(URL, refreshed: Data?)
        /// No bookmark, or one that doesn't open with this app's security scope (a folder that is gone, or a
        /// preset from someone else): the stored path, never where a foreign bookmark points.
        case unconfirmed(URL)

        public var url: URL {
            switch self {
            case .confirmed(let url, _), .unconfirmed(let url): return url
            }
        }

        public var isConfirmed: Bool {
            if case .confirmed = self { return true }
            return false
        }
    }

    /// Resolves the bookmark once. It is followed only when it opens with the app's security scope, or (outside the
    /// real sandbox) when it still points at the stored path; a plain bookmark to somewhere else is ignored.
    public func resolution(resolver: (Data) -> FolderAccess.Resolved? = FolderAccess.resolve,
                           sandboxEnforced: Bool = Sandbox.isEnforced) -> Resolution {
        guard isChosen else { return .unconfirmed(url) }
        guard let bookmark, let found = resolver(bookmark) else { return .unconfirmed(url) }
        if found.isSecurityScoped { return .confirmed(found.url, refreshed: found.refreshed) }
        if !sandboxEnforced, FileIdentity.pathKey(found.url) == FileIdentity.pathKey(url) {
            return .confirmed(found.url, refreshed: found.refreshed)
        }
        return .unconfirmed(url)
    }

    /// This folder updated to where it is now (moved: the new path; stale: the renewed bookmark); nil when nothing
    /// changes or it isn't confirmed.
    public func refreshed(_ resolution: Resolution) -> VariantFolder? {
        guard case .confirmed(let now, let renewed) = resolution else { return nil }
        let newPath = now.standardizedFileURL.path
        guard newPath != path || (renewed != nil && renewed != bookmark) else { return nil }
        return VariantFolder(path: newPath, bookmark: renewed ?? bookmark)
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
    /// The main output's card title (Johan, 2026-11-17): every output is a card under the Output heading, the main
    /// one first, so an added output's default name starts at "Output 2".
    public static let mainOutputName = defaultName(1)

    /// "Output N", the default name of the N-th output card.
    public static func defaultName(_ number: Int) -> String { "Output \(number)" }

    /// The output "+" adds: a copy of the main output's settings (format, compression, quality and the rest; the
    /// same size), named "Output N" after the main output and the ones already there, with a suffix no other output
    /// uses (`_out2`, `_out3`, …), saved beside the main output until another Save to is chosen.
    public static func added(after existing: [OutputVariant], main: OutputSettings) -> OutputVariant {
        let names = Set(existing.map { $0.name.lowercased() })
        let suffixes = Set(existing.map { $0.cleanSuffix.lowercased() })
        let first = existing.count + 2
        let number = (first...(first + maxCount + 1)).first {
            !names.contains(defaultName($0).lowercased()) && !suffixes.contains("_out\($0)")
        } ?? first
        return OutputVariant(name: defaultName(number), settings: main, resize: nil, nameSuffix: "_out\(number)")
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

/// What a run does with an extra output's chosen folder that isn't confirmed (`VariantFolder.Resolution`).
public enum VariantFolderPolicy: Sendable {
    /// The command line: the stored path is used as typed (the folder was named on the command line or in a file
    /// the user passed; the CLI prints every extra output's folder first).
    case trustPaths
    /// The app and jobs: such an output is not written (a note says to choose its folder again); never written
    /// silently to a folder the user didn't choose in this app.
    case confirmedOnly
    /// The app's run: like `confirmedOnly`, but folders the user chose in this run's open panels (`chosen`: stored
    /// paths) are written to even when no bookmark could be made for them (the panel gave this process access).
    case confirmedOr(chosen: Set<String>)

    /// Whether an unconfirmed folder stored as `path` is written to.
    func trustsUnconfirmed(_ path: String) -> Bool {
        switch self {
        case .trustPaths: return true
        case .confirmedOnly: return false
        case .confirmedOr(let chosen): return chosen.contains(path)
        }
    }
}

/// The chosen folders of a batch's extra outputs, resolved once per run (`VariantFolder.resolution`): where each is
/// now, with access started on the resolved URLs for as long as this is kept (the run's lifetime).
final class VariantFolderAccess: @unchecked Sendable {
    /// Stored path → the folder now.
    let folders: [String: URL]
    /// Stored paths that weren't confirmed and that `policy` doesn't trust: not written to.
    let refused: Set<String>
    private let grant: FolderAccess.Grant

    init(_ variants: [OutputVariant], policy: VariantFolderPolicy = .trustPaths,
         resolver: (Data) -> FolderAccess.Resolved? = FolderAccess.resolve) {
        var folders: [String: URL] = [:]
        var refused = Set<String>()
        for variant in variants {
            guard case .folder(let folder)? = variant.destination, folder.isChosen, folders[folder.path] == nil,
                  !refused.contains(folder.path) else { continue }
            let resolution = folder.resolution(resolver: resolver)
            if !resolution.isConfirmed, !policy.trustsUnconfirmed(folder.path) {
                refused.insert(folder.path)
            } else {
                folders[folder.path] = resolution.url
            }
        }
        self.folders = folders
        self.refused = refused
        grant = FolderAccess.Grant(Array(folders.values))
    }

    static let none = VariantFolderAccess([])

    /// The note on an item whose extra output wasn't written because its folder needs choosing again.
    static func refusedNote(_ name: String) -> String {
        "Extra output “\(name)” not written: \(OutputVariant.chooseFolderAgainProblem.lowercased())"
    }
}

extension OutputVariant {
    /// Shown on an output whose chosen folder this app can't confirm (a preset from someone else, a moved or
    /// deleted folder): Run asks for it first.
    public static let chooseFolderAgainProblem = "Choose the folder again"

    /// The output's chosen folder, if it has one.
    public var chosenFolder: VariantFolder? {
        guard case .folder(let folder)? = destination, folder.isChosen else { return nil }
        return folder
    }

    /// Where its files go, for the command line: "/Users/me/Web/big", "next to each original", "“thumbs” next to
    /// each original"; beside the main output: the main output's folder (`main`), or next to each original.
    public func folderDescription(main mode: OutputMode) -> String {
        let below = destination == .sameFolder ? nil : effectiveSubfolder
        func under(_ base: String) -> String { below.map { "\(base)/\($0)" } ?? base }
        switch destination {
        case nil:
            if case .newFolder(let folder) = mode { return under(folder.standardizedFileURL.path) }
            return below.map { "“\($0)” next to each original" } ?? "next to each original"
        case .folder(let folder)?: return under(folder.resolution().url.standardizedFileURL.path)
        case .sameFolder?: return "next to each original"
        case .subfolder(let template)?: return "“\(template)” next to each original"
        }
    }
}

/// The pipeline with every chosen extra-output folder resolved once (`VariantFolder.resolution`).
public struct VariantFolderCheck: Equatable, Sendable {
    /// Confirmed folders updated to where they are now (moved or stale bookmarks rewritten).
    public var pipeline: Pipeline
    /// True when `pipeline` differs from the one checked (save it).
    public var changed: Bool
    /// The outputs whose folder isn't confirmed: the app asks for these before a run.
    public var unconfirmed: [OutputVariant]
}

extension Pipeline {
    public func checkingVariantFolders(resolver: (Data) -> FolderAccess.Resolved? = FolderAccess.resolve,
                                       sandboxEnforced: Bool = Sandbox.isEnforced) -> VariantFolderCheck {
        var copy = self
        var changed = false
        var unconfirmed: [OutputVariant] = []
        for index in copy.extraOutputs.indices {
            guard let folder = copy.extraOutputs[index].chosenFolder else { continue }
            let resolution = folder.resolution(resolver: resolver, sandboxEnforced: sandboxEnforced)
            if let updated = folder.refreshed(resolution) {
                copy.extraOutputs[index].destination = .folder(updated)
                changed = true
            }
            if !resolution.isConfirmed { unconfirmed.append(copy.extraOutputs[index]) }
        }
        return VariantFolderCheck(pipeline: copy, changed: changed, unconfirmed: unconfirmed)
    }
}
