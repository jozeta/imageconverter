import Foundation

/// The "Save into subfolder" template: folder names separated by `/`, each with rename tokens
/// (`{date:yyyy}/{date:MM}`, `{camera}`, `Portraits`). Each folder name is rendered and made safe like a file
/// name, so a token can't add a `/`; empty names, `.` and `..` are dropped (a leading `/` adds nothing), and at
/// most `maxDepth` folders are kept. The result is always inside the folder it is added to.
public enum SubfolderTemplate {
    public static let maxDepth = 5

    /// True when the template has no folder name at all (only slashes and spaces).
    public static func isBlank(_ template: String) -> Bool {
        parts(template).isEmpty
    }

    /// The template's folder parts, before rendering.
    static func parts(_ template: String) -> [RenameTemplate] {
        template.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map(RenameTemplate.init)
    }

    /// The folder names for one file, outermost first.
    static func render(_ parts: [RenameTemplate], _ context: RenameContext) -> [String] {
        Array(parts.map { $0.renderFolderName(context) }.filter(isSafeName).prefix(maxDepth))
    }

    /// The folder names `template` gives for `context` (the editor's example uses it).
    public static func folders(_ template: String, context: RenameContext) -> [String] {
        render(parts(template), context)
    }

    /// A single safe folder name: not empty, not `.` or `..`, no `/` or `:` (sanitising already ensures it;
    /// the planner checks again).
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

/// Finder tags for the "Add Finder tags" action.
public enum FinderTags {
    public static let maxTags = 20
    public static let maxLength = 64
    public static let failedNote = "Finder tags couldn't be added"

    /// Tags cleaned for writing: no control characters, trimmed, at most 64 characters, repeats (ignoring
    /// case) and empty ones dropped, at most 20.
    public static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let clean = String(MetadataFields.sanitized(tag).trimmingCharacters(in: .whitespaces).prefix(maxLength))
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            result.append(clean)
            if result.count == maxTags { break }
        }
        return result
    }

    /// Tags as typed: separated by commas.
    public static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Adds `tags` to the file's own tags; false when they couldn't be set.
    static func add(_ tags: [String], to url: URL) -> Bool {
        let wanted = normalized(tags)
        guard !wanted.isEmpty else { return true }
        let file = URL(fileURLWithPath: url.path)
        let existing = (try? file.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        let present = Set(existing.map { $0.lowercased() })
        let tags = existing + wanted.filter { !present.contains($0.lowercased()) }
        do {
            // NSURL: URLResourceValues' tag setter needs macOS 26.
            try (file as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            return true
        } catch {
            return false
        }
    }
}
