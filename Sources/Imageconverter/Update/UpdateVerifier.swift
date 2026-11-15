import Foundation
import ImageconverterCore

/// The update's working folder and its checks. Every download gets a fresh folder in the app's temporary
/// directory (`imageconverter-update-<uuid>`); `UpdatePackage.prepare` unpacks into `unpacked/` there and checks
/// the checksum, the zip's entries, the layout, links, version and code signature. Folders are deleted on any
/// failure, on Later, after installing, and stale ones at launch.
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

    /// Unpacks and checks off the main actor; returns the new app inside `work`.
    static func verify(zip: URL, sha256: String, version: AppVersion, in work: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try UpdatePackage.prepare(zip: zip, expectedSHA256: sha256, version: version,
                                      into: work.appendingPathComponent("unpacked", isDirectory: true))
        }.value
    }

    static func remove(_ folder: URL?) {
        guard let folder, folder.lastPathComponent.hasPrefix(folderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Folders left by an earlier launch that quit or crashed mid-update.
    static func removeStaleFolders() {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }
}
