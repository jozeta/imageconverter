import Foundation

/// What an `imageconverter://` link asks for. Links are untrusted: any web page or app can open one, so
/// `parse` rejects everything it doesn't know, and the app confirms every action except `open` in a sheet
/// that names what will happen before it changes anything (see `needsConfirmation`).
///
/// - `imageconverter://open` shows the window.
/// - `imageconverter://preset?name=Web%20export` selects a preset.
/// - `imageconverter://add?path=/Users/me/a.jpg&path=/Users/me/Trip` adds files and folders.
/// - `imageconverter://jobs/run?name=Nightly` runs a saved job.
public enum URLAction: Equatable, Sendable {
    case open
    case selectPreset(name: String)
    case addFiles([URL])
    case runJob(name: String)

    public static let scheme = "imageconverter"
    /// Longer links are rejected before they are parsed.
    public static let maxURLLength = 16_384
    /// The same limit as preset and job names.
    public static let maxNameLength = PresetStore.maxNameLength
    public static let maxPaths = 50
    public static let maxPathLength = 1024

    /// Everything but `open` changes the app or writes files, so the app asks first.
    public var needsConfirmation: Bool {
        if case .open = self { return false }
        return true
    }

    /// A file or folder that exists and this user can read.
    public static func isReadableItem(_ url: URL) -> Bool {
        let path = url.path
        return FileManager.default.fileExists(atPath: path) && FileManager.default.isReadableFile(atPath: path)
    }

    /// The action for a link, or nil when anything about it is unknown, duplicated, too long or (for `add`)
    /// names a path that doesn't exist or can't be read. `isReadable` is injectable for tests.
    public static func parse(_ url: URL, isReadable: (URL) -> Bool = isReadableItem) -> URLAction? {
        guard url.absoluteString.utf8.count <= maxURLLength,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              let query = Query(components.queryItems ?? [])
        else { return nil }
        let path = components.path

        switch host {
        case "open":
            guard isRoot(path), query.isEmpty else { return nil }
            return .open
        case "preset":
            guard isRoot(path), let name = query.single("name", only: true).flatMap(validatedName) else { return nil }
            return .selectPreset(name: name)
        case "jobs":
            guard path == "/run", let name = query.single("name", only: true).flatMap(validatedName) else { return nil }
            return .runJob(name: name)
        case "add":
            guard isRoot(path), query.names == ["path"] else { return nil }
            return validatedPaths(query.values("path"), isReadable: isReadable).map(URLAction.addFiles)
        default:
            return nil
        }
    }

    private static func isRoot(_ path: String) -> Bool { path.isEmpty || path == "/" }

    /// Trimmed, 1...80 characters, no control characters. Matching a real preset or job is the app's job.
    static func validatedName(_ raw: String) -> String? {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= maxNameLength else { return nil }
        return name
    }

    /// Absolute paths only (no `~`, no relative paths), each readable; duplicates are dropped.
    /// One bad path rejects the whole link, so nothing is added half-way.
    static func validatedPaths(_ raw: [String], isReadable: (URL) -> Bool) -> [URL]? {
        guard !raw.isEmpty, raw.count <= maxPaths else { return nil }
        var urls: [URL] = []
        for path in raw {
            guard path.hasPrefix("/"), path.utf8.count <= maxPathLength, !path.contains("\0"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard isReadable(url) else { return nil }
            if !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    /// The query items, rejecting items without a value or with an empty one.
    private struct Query {
        let items: [(name: String, value: String)]

        init?(_ raw: [URLQueryItem]) {
            var items: [(String, String)] = []
            for item in raw {
                guard let value = item.value, !value.isEmpty, !item.name.isEmpty else { return nil }
                items.append((item.name, value))
            }
            self.items = items
        }

        var isEmpty: Bool { items.isEmpty }
        var names: Set<String> { Set(items.map(\.name)) }

        func values(_ name: String) -> [String] { items.filter { $0.name == name }.map(\.value) }

        /// The value of `name` when it appears exactly once (and, with `only`, nothing else does).
        func single(_ name: String, only: Bool) -> String? {
            let found = values(name)
            guard found.count == 1, !only || items.count == 1 else { return nil }
            return found[0]
        }
    }
}
