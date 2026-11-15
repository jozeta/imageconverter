import Foundation
import ImageconverterCore

/// The app's download folder: every download gets a fresh folder in the app's temporary directory
/// (`imageconverter-update-<uuid>`, the name the installer service expects). The app checks the zip's SHA-256 for fast
/// feedback; unpacking and every other check happen in the installer service. Folders are deleted on failure, on
/// Later, after installing, and stale ones at launch.
enum UpdateVerifier {
    static let folderPrefix = "imageconverter-update-"

    static func makeWorkFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            throw UpdateError.downloadFailed("no temporary folder could be made.")
        }
        return folder
    }

    /// Throws `.checksumMismatch` unless the zip's SHA-256 is `expected` (off the main actor).
    static func checkChecksum(of zip: URL, expected: String) async throws {
        let actual = try await Task.detached(priority: .userInitiated) { try UpdatePackage.sha256(of: zip) }.value
        guard actual == expected.lowercased() else { throw UpdateError.checksumMismatch }
    }

    static func remove(_ folder: URL?) {
        guard let folder, folder.lastPathComponent.hasPrefix(folderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes folders left by an earlier launch that quit or crashed mid-update; true when there were any.
    @discardableResult
    static func removeStaleFolders() -> Bool {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        let stale = names.filter { $0.hasPrefix(folderPrefix) }
        for name in stale { try? FileManager.default.removeItem(at: temp.appendingPathComponent(name)) }
        return !stale.isEmpty
    }
}
