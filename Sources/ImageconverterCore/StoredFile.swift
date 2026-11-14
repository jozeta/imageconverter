import Foundation

/// The hardened reading and naming rules shared by `PresetStore` and `TemplateStore`: files in these
/// folders are untrusted (they may have been dropped there by anything).
enum StoredFile {
    static let maxFileSize = 1_048_576

    /// Opens without following links or blocking, checks the open descriptor, and reads at most `maxSize` + 1 byte
    /// (1 MB by default; job ledgers allow more).
    static func readData(_ url: URL, maxSize: Int = maxFileSize) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw PresetError.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw PresetError.notRegularFile
        }
        guard info.st_size <= maxSize else { throw PresetError.tooLarge }
        guard let data = try? handle.read(upToCount: maxSize + 1) else { throw PresetError.unreadable }
        guard data.count <= maxSize else { throw PresetError.tooLarge }
        return data
    }

    static func decodeError(_ error: Error) -> PresetError {
        if let decoding = error as? DecodingError, case .dataCorrupted(let context) = decoding,
           context.underlyingError != nil || context.debugDescription.contains("JSON") {
            return .invalidJSON
        }
        return .invalidStructure
    }

    /// Every Unicode whitespace character (non-breaking space included) becomes one space; runs
    /// collapse and the ends are trimmed, so look-alike names can't coexist.
    static func normalizeWhitespace(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) || scalar.properties.isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(scalar)
            }
        }
        return String(result)
    }

    static func fold(_ name: String) -> String {
        normalizeWhitespace(name).folding(options: [.caseInsensitive], locale: nil)
    }

    /// Control characters are removed, the result is trimmed, 1...maxLength characters, unique ignoring case.
    static func validatedName(_ raw: String, existing: [(id: UUID, name: String)], excluding: UUID?,
                              maxLength: Int, noun: String) throws -> String {
        let stripped = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }))
        let cleaned = normalizeWhitespace(stripped)
        guard !cleaned.isEmpty else { throw PresetError.invalidName("Enter a name for the \(noun).") }
        guard cleaned.count <= maxLength else {
            throw PresetError.invalidName("The name can be at most \(maxLength) characters.")
        }
        let key = fold(cleaned)
        if existing.contains(where: { $0.id != excluding && fold($0.name) == key }) {
            throw PresetError.duplicateName
        }
        return cleaned
    }
}

extension PresetError {
    /// The message with "preset" replaced by another noun ("template"), for the other stores.
    public func reason(noun: String) -> String {
        reason.replacingOccurrences(of: "preset", with: noun)
            .replacingOccurrences(of: "Preset", with: noun.prefix(1).uppercased() + noun.dropFirst())
    }
}
