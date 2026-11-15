import CryptoKit
import Foundation

/// Checks a downloaded update zip and unpacks it, without networking: the SHA-256, the zip's entry names
/// (before anything is written), `/usr/bin/ditto -x -k` into a fresh folder, exactly one top-level
/// `imageconverter.app`, no symlink leading outside it, the bundle's version, and last its code signature
/// (`UpdateSignature`). Any failure deletes the unpack folder; the installed app is never touched here.
public enum UpdatePackage {
    public struct Listing: Equatable, Sendable {
        public var names: [String]
        public var symlinks: [String]
    }

    /// Unpacks `zip` into `folder` (which must not exist yet; it is created) and returns the checked app inside it.
    /// `requirement` is the code requirement the app must meet (tests pass a looser one for the later steps).
    public static func prepare(zip: URL, expectedSHA256: String, version: AppVersion, into folder: URL,
                               requirement: String = UpdatePolicy.codeRequirement) throws -> URL {
        guard try sha256(of: zip) == expectedSHA256.lowercased() else { throw UpdateError.checksumMismatch }
        let listing = try listEntries(of: zip)
        if let problem = entryProblem(names: listing.names, symlinks: listing.symlinks) { throw UpdateError.badPackage(problem) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            throw UpdateError.badPackage("its unpack folder could not be created")
        }
        do {
            guard try runTool("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip.path, folder.path]).status == 0 else {
                throw UpdateError.badPackage("the zip could not be unpacked")
            }
            let app = try locateApp(in: folder)
            if let link = symlinkEscaping(app) { throw UpdateError.badPackage("the link \u{201C}\(link)\u{201D} points outside the app") }
            try checkVersion(of: app, version: version)
            try UpdateSignature.check(app, requirement: requirement)
            return app
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Lowercase hex SHA-256 of a file, read in chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Zip entries

    /// The zip's entry names and which of them are symlinks (`zipinfo`, which only reads the archive).
    public static func listEntries(of archive: URL) throws -> Listing {
        let names = try runTool("/usr/bin/zipinfo", ["-1", archive.path])
        let long = try runTool("/usr/bin/zipinfo", ["-s", archive.path])
        guard names.status == 0, long.status == 0, let nameText = String(data: names.output, encoding: .utf8),
              let longText = String(data: long.output, encoding: .utf8) else {
            throw UpdateError.badPackage("the zip could not be read")
        }
        let entries = nameText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        // In `-s` output, one line per entry starts with a 10-character permission string.
        let lines = longText.split(separator: "\n").map(String.init).filter(isEntryLine)
        guard lines.count == entries.count else { throw UpdateError.badPackage("the zip's entries could not be listed") }
        var symlinks: [String] = []
        for (line, name) in zip(lines, entries) {
            guard line.hasSuffix(name) else { throw UpdateError.badPackage("the zip's entries could not be listed") }
            if line.hasPrefix("l") { symlinks.append(name) }
        }
        return Listing(names: entries, symlinks: symlinks)
    }

    private static func isEntryLine(_ line: String) -> Bool {
        let permissions = line.prefix(10)
        return permissions.count == 10 && "-dlbcps".contains(permissions.first ?? " ")
            && permissions.dropFirst().allSatisfy { "rwxsStT-".contains($0) }
    }

    /// Why the entries are not one plain `imageconverter.app` folder, or nil: every name inside it, no absolute
    /// path, no `.`/`..`/empty component, no NUL, and nothing written through a symlink entry.
    public static func entryProblem(names: [String], symlinks: [String]) -> String? {
        let top = UpdatePolicy.appBundleName
        guard !names.isEmpty else { return "the zip is empty" }
        for name in names {
            guard name == top + "/" || name.hasPrefix(top + "/") else { return "it holds something besides \(top)" }
            var components = name.split(separator: "/", omittingEmptySubsequences: false)
            if name.hasSuffix("/") { components.removeLast() }
            if name.unicodeScalars.contains(where: { $0.value == 0 })
                || components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                return "it has an unsafe entry name"
            }
        }
        for link in symlinks where names.contains(where: { $0.hasPrefix(link + "/") }) {
            return "it writes through the link \u{201C}\(link)\u{201D}"
        }
        return nil
    }

    // MARK: After unpacking

    /// The one top-level item, which must be the folder `imageconverter.app` (not a link).
    public static func locateApp(in folder: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard items == [UpdatePolicy.appBundleName] else { throw UpdateError.badPackage("it must hold only \(UpdatePolicy.appBundleName)") }
        let app = folder.appendingPathComponent(UpdatePolicy.appBundleName, isDirectory: true)
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw UpdateError.badPackage("\(UpdatePolicy.appBundleName) is not a folder")
        }
        return app
    }

    /// The bundle-relative path of the first symlink that is absolute, dangling, or resolves outside `bundle`.
    public static func symlinkEscaping(_ bundle: URL) -> String? {
        guard let base = realPath(bundle.path) else { return "." }
        guard let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return "."
        }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let relative = url.path.hasPrefix(bundle.path + "/") ? String(url.path.dropFirst(bundle.path.count + 1)) : url.lastPathComponent
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path), !target.hasPrefix("/"),
                  let resolved = realPath(url.path), resolved == base || resolved.hasPrefix(base + "/") else { return relative }
        }
        return nil
    }

    /// The bundle's `CFBundleShortVersionString` must be exactly the release's version.
    public static func checkVersion(of bundle: URL, version: AppVersion) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist), data.count <= 1_000_000,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = info["CFBundleShortVersionString"] as? String, AppVersion(text) == version
        else { throw UpdateError.versionMismatch }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Runs a system tool and returns its exit status and standard output (standard error is discarded).
    static func runTool(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.badPackage("\(URL(fileURLWithPath: path).lastPathComponent) could not run") }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
