import Foundation

/// A named, saved set of options of one kind (metadata, watermark, job, ...).
public struct Template<Payload: Codable & Sendable>: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var payload: Payload
    /// True for the templates that ship with the app. Never stored in a file.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, payload: Payload, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.payload = payload
        self.isBuiltIn = isBuiltIn
    }

    /// The version of the top-level template file format.
    public static var schemaVersion: Int { 1 }

    private enum CodingKeys: String, CodingKey { case schemaVersion, id, name, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        payload = try container.decode(Payload.self, forKey: .payload)
        isBuiltIn = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(payload, forKey: .payload)
    }
}

extension Template: Equatable where Payload: Equatable {}

public struct TemplateLoadResult<Payload: Codable & Sendable> {
    public var templates: [Template<Payload>]
    public var skipped: [(file: String, reason: String)]
}

/// Reads and writes templates as one JSON file per template, named after its UUID, with the same file
/// hardening as `PresetStore` (see `StoredFile`). One instance per directory: its lock only serialises
/// calls on that instance.
public final class TemplateStore<Payload: Codable & Sendable>: @unchecked Sendable {
    public static var maxNameLength: Int { 80 }

    private let directory: URL
    private let builtIns: [Template<Payload>]
    /// "template" in messages, e.g. "A template with this name already exists."
    private let noun: String
    private let lock = NSLock()

    public init(directory: URL, builtIns: [Template<Payload>] = [], noun: String = "template") {
        self.directory = directory
        self.builtIns = builtIns.map { template in
            var copy = template
            copy.isBuiltIn = true
            return copy
        }
        self.noun = noun
    }

    /// `~/Library/Application Support/imageconverter/<folder>/`.
    public static func defaultDirectory(folder: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("imageconverter", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    private func isBuiltIn(_ id: UUID) -> Bool { builtIns.contains { $0.id == id } }

    private func validatedName(_ raw: String, existing: [Template<Payload>], excluding: UUID?) throws -> String {
        try StoredFile.validatedName(raw, existing: existing.map { ($0.id, $0.name) }, excluding: excluding,
                                     maxLength: Self.maxNameLength, noun: noun)
    }

    // MARK: Loading

    private struct Header: Decodable { let schemaVersion: Int? }

    /// The built-ins first, then the user's templates by name, plus the files that were skipped and why.
    public func load() -> TemplateLoadResult<Payload> {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> TemplateLoadResult<Payload> {
        var user: [Template<Payload>] = []
        var skipped: [(file: String, reason: String)] = []
        var seenNames = Set(builtIns.map { StoredFile.fold($0.name) })
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        } catch {
            if FileManager.default.fileExists(atPath: directory.path) {
                skipped.append((directory.lastPathComponent, "The \(noun)s folder couldn't be read."))
            }
            return TemplateLoadResult(templates: builtIns, skipped: skipped)
        }
        let candidates = files.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in candidates {
            guard let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let file = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                skipped.append((file, PresetError.notRegularFile.reason(noun: noun)))
                continue
            }
            do {
                let template = try read(url, expectedID: fileID)
                guard seenNames.insert(StoredFile.fold(template.name)).inserted else {
                    skipped.append((file, PresetError.duplicateName.reason(noun: noun)))
                    continue
                }
                user.append(template)
            } catch let error as PresetError {
                skipped.append((file, error.reason(noun: noun)))
            } catch {
                skipped.append((file, PresetError.unreadable.reason(noun: noun)))
            }
        }
        user.sort {
            let order = $0.name.caseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        skipped.sort { $0.file < $1.file }
        return TemplateLoadResult(templates: builtIns + user, skipped: skipped)
    }

    private func read(_ url: URL, expectedID: UUID) throws -> Template<Payload> {
        let data = try StoredFile.readData(url)
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) } catch { throw StoredFile.decodeError(error) }
        let version = header.schemaVersion ?? 1
        guard version <= Template<Payload>.schemaVersion else { throw PresetError.unsupportedVersion(version) }
        var template: Template<Payload>
        do { template = try decoder.decode(Template<Payload>.self, from: data) } catch {
            throw StoredFile.decodeError(error)
        }
        guard template.id == expectedID else { throw PresetError.idMismatch }
        guard !isBuiltIn(template.id) else { throw PresetError.builtInID }
        guard let name = try? validatedName(template.name, existing: [], excluding: nil) else {
            throw PresetError.invalidName("The \(noun) has no valid name.")
        }
        template.name = name
        return template
    }

    // MARK: Writing

    public func save(_ template: Template<Payload>) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !template.isBuiltIn, !isBuiltIn(template.id) else { throw PresetError.builtInReadOnly }
        var stored = template
        stored.name = try validatedName(template.name, existing: loadUnlocked().templates, excluding: template.id)
        try write(stored)
    }

    public func rename(id: UUID, to newName: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isBuiltIn(id) else { throw PresetError.builtInReadOnly }
        let templates = loadUnlocked().templates
        guard var template = templates.first(where: { $0.id == id }) else { throw PresetError.unreadable }
        template.name = try validatedName(newName, existing: templates, excluding: id)
        try write(template)
    }

    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isBuiltIn(id) else { throw PresetError.builtInReadOnly }
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func write(_ template: Template<Payload>) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(template).write(to: fileURL(for: template.id), options: .atomic)
    }
}
