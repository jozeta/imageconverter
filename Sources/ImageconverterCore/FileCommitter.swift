import Foundation

/// Moves a file to the Trash. Injected so tests never touch the real Trash.
public typealias Trasher = @Sendable (URL) throws -> Void

/// Moves a file to the user's Trash.
public let systemTrash: Trasher = { url in
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
}

public enum FileCommitter {
    /// Prefix of the hidden temporary files written next to the destination.
    public static let tempPrefix = ".imageconverter-"

    /// Writes `data` next to its destination as a temporary file, then moves it into place, so a
    /// half-written file never appears under the final name. An existing file is only replaced
    /// when `plan.replacesSource` is set; otherwise an existing destination makes this fail.
    /// The original is trashed only after the new file is in place. If trashing fails, the new
    /// file stays and `.writeFailed("Converted, but couldn't move the original to the Trash: …")`
    /// is thrown. Every other failure removes the temp file and throws `.writeFailed`.
    public static func commit(_ data: Data, for plan: PlannedOutput, trash: Trasher = systemTrash) throws {
        let files = FileManager.default
        let directory = plan.destination.deletingLastPathComponent()
        let temp = directory.appendingPathComponent("\(tempPrefix)\(UUID().uuidString).tmp")

        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp, options: [.withoutOverwriting])
            if plan.replacesSource {
                _ = try files.replaceItemAt(plan.destination, withItemAt: temp)
            } else {
                try files.moveItem(at: temp, to: plan.destination)
            }
        } catch {
            try? files.removeItem(at: temp)
            throw ConversionError.writeFailed(error.localizedDescription)
        }

        if plan.trashesSource {
            do {
                try trash(plan.item.source)
            } catch {
                throw ConversionError.writeFailed(
                    "Converted, but couldn't move the original to the Trash: \(error.localizedDescription)")
            }
        }
    }
}
