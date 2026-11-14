import Foundation

/// What a branch of a condition does to one image.
public enum ConditionalAction: Codable, Equatable, Sendable {
    /// An image step, inserted where the condition stands. Never another condition (no nesting).
    case step(PipelineStep)
    /// Replaces the pipeline's output settings for this image.
    case output(OutputSettings)
    /// Replaces the Metadata step's settings for this image (switched on).
    case metadata(MetadataOptions)
    /// Replaces the Rename step's settings for this image (switched on).
    case rename(RenameOptions)
    /// Writes the source's bytes unchanged, with its own extension; nothing is decoded.
    case copyOriginal
    /// Writes nothing; reported as skipped by a condition, not as a failure.
    case skip
    /// Saves into a subfolder of the output folder (or of the source's folder): a template with rename tokens,
    /// `/` between folders (`{date:yyyy}/{date:MM}`). Ignored when overwriting originals.
    case subfolder(String)
    /// Finder tags added to the written file.
    case finderTags([String])
    /// A saved preset's image steps, inserted here, and its output, metadata and rename settings.
    case preset(PresetLink)
    /// Keywords added to the file's own (the Metadata step's removals still apply).
    case addKeywords([String])
    /// No later condition step is checked for this image.
    case stop
    /// A line in the report for this file (rename tokens allowed).
    case note(String)

    public static let maxNoteLength = 200

    /// False for a nested condition or an empty or oversized value; such actions are dropped on load.
    public var isValid: Bool {
        switch self {
        case .step(let step):
            if case .condition = step.operation { return false }
            return true
        case .subfolder(let template):
            return !SubfolderTemplate.isBlank(template) && template.count <= RenameTemplate.maxLength
        case .finderTags(let tags):
            return tags.count <= FinderTags.maxTags * 2 && !FinderTags.normalized(tags).isEmpty
        case .addKeywords(let keywords):
            return keywords.count <= MetadataFields.maxKeywords * 2 && !MetadataFields.normalizedKeywords(keywords).isEmpty
        case .note(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= Self.maxNoteLength
        case .preset(let link):
            return link.name.count <= PresetStore.maxNameLength
        case .output, .metadata, .rename, .copyOriginal, .skip, .stop:
            return true
        }
    }
}

/// A saved preset an action applies, by id; the name is kept for the editor and for the note when the preset
/// is gone.
public struct PresetLink: Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    public init(_ preset: Preset) {
        self.init(id: preset.id, name: preset.name)
    }

    /// The report's note when the preset no longer exists.
    public var missingNote: String { "Preset “\(name)” wasn't found, so it wasn't applied" }
}

/// The presets an "Apply preset" action can use: the built-ins and the files of one presets folder, read again
/// whenever the folder changes. One instance per folder (`folder(_:)`); the app, the command line and each job
/// pass the one for their own folder, and `standard` is the default folder's.
public final class PresetLibrary: @unchecked Sendable {
    private let directory: URL?
    private let lock = NSLock()
    private var presets: [UUID: Preset] = [:]
    /// The folder's modification date when it was last read; nil before the first read.
    private var stamp: Date??

    private init(directory: URL?) {
        self.directory = directory
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: PresetLibrary] = [:]

    /// The library of `directory`, shared by everyone who asks for that folder.
    public static func folder(_ directory: URL) -> PresetLibrary {
        let key = directory.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let library = registry[key] { return library }
        let library = PresetLibrary(directory: directory.standardizedFileURL)
        registry[key] = library
        return library
    }

    /// The default presets folder's library.
    public static var standard: PresetLibrary { folder(PresetStore.defaultDirectory) }

    /// Only the built-in presets (no folder).
    public static let builtInsOnly = PresetLibrary(directory: nil)

    /// The preset with `id`, or nil when there is none.
    public func preset(id: UUID) -> Preset? {
        if let builtIn = PresetStore.builtIns.first(where: { $0.id == id }) { return builtIn }
        guard let directory else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // A fresh URL: a URL caches its resource values. Saving, renaming or deleting a preset changes the folder.
        let current = (try? URL(fileURLWithPath: directory.path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let isCurrent: Bool
        if case .some(let seen) = stamp { isCurrent = seen == current } else { isCurrent = false }
        if !isCurrent {
            presets = Dictionary(PresetStore(directory: directory).loadAll().presets.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
            stamp = .some(current)
        }
        return presets[id]
    }
}
