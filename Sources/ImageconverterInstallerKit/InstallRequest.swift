import Foundation
import ImageconverterCore

/// Pure checks on what the service is asked to do. Nothing from the client is trusted: the app to replace comes from
/// the service's own location, and the zip must be where the app downloads it.
public enum InstallRequest {
    /// `…/X.app/Contents/XPCServices/Y.xpc` → `…/X.app`; nil for any other shape.
    public static func targetApp(forService service: URL) -> URL? {
        let service = service.standardizedFileURL
        let xpcServices = service.deletingLastPathComponent()
        let contents = xpcServices.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard service.pathExtension == "xpc", xpcServices.lastPathComponent == "XPCServices",
              contents.lastPathComponent == "Contents", app.pathExtension == "app", app.path != "/" else { return nil }
        return app
    }

    /// Why `path` is not the app's download, or nil. It must be exactly
    /// `<home>/Library/Containers/<client>/Data/tmp/imageconverter-update-<UUID>/imageconverter-<version>.zip`.
    public static func zipPathProblem(_ path: String, home: String, clientBundleID: String, version: AppVersion) -> String? {
        let refused = "The update's download is not where the app keeps it."
        guard path.hasPrefix("/"), !clientBundleID.isEmpty, !clientBundleID.contains("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return refused }
        let tmp = URL(fileURLWithPath: home).appendingPathComponent("Library/Containers")
            .appendingPathComponent(clientBundleID).appendingPathComponent("Data/tmp").standardizedFileURL.path
        guard path.hasPrefix(tmp + "/") else { return refused }
        let rest = path.dropFirst(tmp.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard rest.count == 2, rest[0].hasPrefix(InstallerPolicy.clientFolderPrefix),
              UUID(uuidString: String(rest[0].dropFirst(InstallerPolicy.clientFolderPrefix.count))) != nil,
              rest[1] == UpdatePolicy.zipName(for: version) else { return refused }
        return nil
    }

    /// 64 hex digits.
    public static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    /// Copies a regular file (never through a symlink) of at most `maxBytes` to `destination`.
    public static func copyZip(at path: String, to destination: URL, maxBytes: Int) throws {
        let refused = UpdateError.installRefused("The update's download is not where the app keeps it.")
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw refused }
        let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw refused }
        guard info.st_size <= maxBytes else { throw UpdateError.downloadTooLarge }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else {
            throw UpdateError.installFailed("the download could not be copied.")
        }
        defer { try? output.close() }
        var copied = 0
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            copied += chunk.count
            guard copied <= maxBytes else { throw UpdateError.downloadTooLarge }
            try output.write(contentsOf: chunk)
        }
    }
}
