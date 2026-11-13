import Foundation

/// A named, saved pipeline. Output mode is not part of a preset; only the pipeline is.
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var pipeline: Pipeline
    /// True for the presets that ship with the app. Never stored in a file.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, pipeline: Pipeline, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.pipeline = pipeline
        self.isBuiltIn = isBuiltIn
    }

    /// The version of the top-level preset file format.
    public static let schemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, pipeline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        pipeline = try container.decode(Pipeline.self, forKey: .pipeline)
        isBuiltIn = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(pipeline, forKey: .pipeline)
    }
}

public enum PresetError: Error, Equatable {
    case invalidName(String)
    case duplicateName
    case builtInReadOnly
    case unsupportedVersion(Int)
    case tooLarge
    case unreadable
    case notRegularFile
    case invalidJSON
    case invalidStructure
    case folderUnreadable

    public var reason: String {
        switch self {
        case .invalidName(let message): return message
        case .duplicateName: return "A preset with this name already exists."
        case .builtInReadOnly: return "Built-in presets can't be changed. Save a copy under a new name."
        case .unsupportedVersion(let version):
            return "This preset was saved by a newer version of the app (format \(version))."
        case .tooLarge: return "The preset file is larger than 1 MB."
        case .unreadable: return "The preset file couldn't be read."
        case .notRegularFile: return "Not a regular file (links and special files are ignored)."
        case .invalidJSON: return "The preset file isn't valid JSON."
        case .invalidStructure: return "The preset file has missing or wrongly typed fields."
        case .folderUnreadable: return "The presets folder couldn't be read."
        }
    }
}

public struct PresetLoadResult {
    public var presets: [Preset]
    public var skipped: [(file: String, reason: String)]
}

/// Reads and writes presets as one JSON file per preset, named after the preset's UUID.
/// Meant to be a single shared instance per directory: its lock only serialises calls on that instance.
public final class PresetStore: @unchecked Sendable {
    public static let maxFileSize = 1_048_576
    public static let maxNameLength = 80

    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("imageconverter", isDirectory: true)
            .appendingPathComponent("presets", isDirectory: true)
    }

    // MARK: Built-ins

    // swiftlint:disable force_unwrapping
    private static let webExportID = UUID(uuidString: "B1A5E000-0000-4000-8000-000000000001")!
    private static let instagramID = UUID(uuidString: "B1A5E000-0000-4000-8000-000000000002")!
    private static let archiveID = UUID(uuidString: "B1A5E000-0000-4000-8000-000000000003")!
    private static let webResizeStepID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000A1")!
    private static let webColorStepID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000A2")!
    private static let instaResizeStepID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000B1")!
    private static let instaColorStepID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000B2")!
    // swiftlint:enable force_unwrapping

    public static let builtIns: [Preset] = [
        Preset(id: webExportID, name: "Web export", pipeline: Pipeline(
            steps: [
                PipelineStep(id: webResizeStepID,
                             operation: .resize(ResizeOptions(mode: .fitBox(width: 2048, height: 2048)))),
                PipelineStep(id: webColorStepID, operation: .colorProfile(.sRGB))
            ],
            output: OutputSettings(format: .jpeg, quality: 0.82),
            metadata: MetadataOptions(isEnabled: true, removeLocation: true)), isBuiltIn: true),
        Preset(id: instagramID, name: "Instagram 4:5", pipeline: Pipeline(
            steps: [
                PipelineStep(id: instaResizeStepID, operation: .resize(ResizeOptions(
                    mode: .exactSize(width: 1080, height: 1350, fill: .fillAndCrop)))),
                PipelineStep(id: instaColorStepID, operation: .colorProfile(.sRGB))
            ],
            output: OutputSettings(format: .jpeg, quality: 0.85),
            metadata: MetadataOptions(isEnabled: true, removeLocation: true)), isBuiltIn: true),
        Preset(id: archiveID, name: "Archive TIFF", pipeline: Pipeline(
            steps: [],
            output: OutputSettings(format: .tiff, tiffCompression: .lzw),
            metadata: MetadataOptions(isEnabled: false)), isBuiltIn: true)
    ]

    private static func isBuiltIn(_ id: UUID) -> Bool {
        builtIns.contains { $0.id == id }
    }

    // MARK: Names

    /// Control characters are removed, the result is trimmed, 1...80 characters, unique ignoring case.
    public static func validatedName(_ raw: String, existing: [Preset], excluding: UUID?) throws -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        })).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { throw PresetError.invalidName("Enter a name for the preset.") }
        guard cleaned.count <= maxNameLength else {
            throw PresetError.invalidName("The name can be at most \(maxNameLength) characters.")
        }
        let key = fold(cleaned)
        if existing.contains(where: { $0.id != excluding && fold($0.name) == key }) {
            throw PresetError.duplicateName
        }
        return cleaned
    }

    private static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: nil)
    }

    // MARK: Loading

    private struct Header: Decodable {
        let schemaVersion: Int?
    }

    public func loadAll() -> PresetLoadResult {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> PresetLoadResult {
        var user: [Preset] = []
        var skipped: [(file: String, reason: String)] = []
        var seenNames = Set(Self.builtIns.map { Self.fold($0.name) })
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        } catch {
            // A folder that doesn't exist yet is normal; anything else is reported.
            if FileManager.default.fileExists(atPath: directory.path) {
                skipped.append((directory.lastPathComponent, PresetError.folderUnreadable.reason))
            }
            return PresetLoadResult(presets: Self.builtIns, skipped: skipped)
        }
        let candidates = files.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in candidates {
            guard let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let file = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                skipped.append((file, PresetError.notRegularFile.reason))
                continue
            }
            do {
                let preset = try Self.read(url, expectedID: fileID)
                guard seenNames.insert(Self.fold(preset.name)).inserted else {
                    skipped.append((file, PresetError.duplicateName.reason))
                    continue
                }
                user.append(preset)
            } catch let error as PresetError {
                skipped.append((file, error.reason))
            } catch {
                skipped.append((file, PresetError.unreadable.reason))
            }
        }
        user.sort {
            let order = $0.name.caseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        skipped.sort { $0.file < $1.file }
        return PresetLoadResult(presets: Self.builtIns + user, skipped: skipped)
    }

    /// Opens without following links or blocking, checks the open descriptor, and reads at most 1 MB + 1 byte.
    private static func readData(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw PresetError.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw PresetError.notRegularFile
        }
        guard info.st_size <= maxFileSize else { throw PresetError.tooLarge }
        guard let data = try? handle.read(upToCount: maxFileSize + 1) else { throw PresetError.unreadable }
        guard data.count <= maxFileSize else { throw PresetError.tooLarge }
        return data
    }

    private static func decodeError(_ error: Error) -> PresetError {
        if let decoding = error as? DecodingError, case .dataCorrupted(let context) = decoding,
           context.underlyingError != nil || context.debugDescription.contains("JSON") {
            return .invalidJSON
        }
        return .invalidStructure
    }

    private static func read(_ url: URL, expectedID: UUID) throws -> Preset {
        let data = try readData(url)
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) } catch { throw decodeError(error) }
        let version = header.schemaVersion ?? 1
        guard version <= Preset.schemaVersion else { throw PresetError.unsupportedVersion(version) }
        var preset: Preset
        do { preset = try decoder.decode(Preset.self, from: data) } catch { throw decodeError(error) }
        guard preset.id == expectedID, !isBuiltIn(preset.id) else { throw PresetError.unreadable }
        guard let name = try? validatedName(preset.name, existing: [], excluding: nil) else {
            throw PresetError.invalidName("The preset has no valid name.")
        }
        preset.name = name
        return preset
    }

    // MARK: Writing

    public func save(_ preset: Preset) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !preset.isBuiltIn, !Self.isBuiltIn(preset.id) else { throw PresetError.builtInReadOnly }
        var stored = preset
        stored.name = try Self.validatedName(
            preset.name, existing: loadUnlocked().presets, excluding: preset.id)
        try write(stored)
    }

    public func rename(id: UUID, to newName: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !Self.isBuiltIn(id) else { throw PresetError.builtInReadOnly }
        let presets = loadUnlocked().presets
        guard var preset = presets.first(where: { $0.id == id }) else { throw PresetError.unreadable }
        preset.name = try Self.validatedName(newName, existing: presets, excluding: id)
        try write(preset)
    }

    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !Self.isBuiltIn(id) else { throw PresetError.builtInReadOnly }
        let url = fileURL(for: id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func write(_ preset: Preset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preset)
        try data.write(to: fileURL(for: preset.id), options: .atomic)
    }
}

extension PresetStore {
    /// The user's own presets from a load result (which also lists the built-ins), sorted by name.
    public static func userPresets(from presets: [Preset]) -> [Preset] {
        presets.filter { !$0.isBuiltIn }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
