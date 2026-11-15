import CryptoKit
import Foundation

/// Checks a downloaded update zip and unpacks it, without networking: the SHA-256, the zip's entry names, count and
/// total unpacked size (before anything is written, `Limits`), `/usr/bin/ditto -x -k` into a fresh folder, exactly one top-level
/// `imageconverter.app`, no symlink leading outside it, the bundle's version, and last its code signature
/// (`UpdateSignature`). Any failure deletes the unpack folder; the installed app is never touched here.
public enum UpdatePackage {
    public struct Listing: Equatable, Sendable {
        public var names: [String]
        public var symlinks: [String]
        /// The sum of the entries' unpacked sizes as the zip declares them.
        public var uncompressedBytes: Int64 = 0
    }

    /// Caps checked on the listing before unpacking (a 200 MB zip could otherwise inflate to fill the disk or list
    /// millions of entries, all before the signature can be checked).
    public struct Limits: Equatable, Sendable {
        public var maxEntries: Int
        public var maxUncompressedBytes: Int64
        /// Each `zipinfo` listing read is refused past this many bytes.
        public var maxListingBytes: Int
        /// The unpack watchdog stops `ditto` once more than `maxUncompressedBytes + unpackMargin` bytes are in the
        /// unpack folder (a zip can declare smaller sizes than it inflates to), or the volume has less than
        /// `minFreeBytes` left; it looks every `pollInterval` seconds.
        public var unpackMargin: Int64
        public var minFreeBytes: Int64
        public var pollInterval: TimeInterval

        public init(maxEntries: Int, maxUncompressedBytes: Int64, maxListingBytes: Int, unpackMargin: Int64 = 64 << 20,
                    minFreeBytes: Int64 = 2 << 30, pollInterval: TimeInterval = 0.25) {
            self.maxEntries = maxEntries
            self.maxUncompressedBytes = maxUncompressedBytes
            self.maxListingBytes = maxListingBytes
            self.unpackMargin = unpackMargin
            self.minFreeBytes = minFreeBytes
            self.pollInterval = pollInterval
        }

        public static let standard = Limits(maxEntries: 20_000, maxUncompressedBytes: 1 << 30, maxListingBytes: 8 << 20)
    }

    /// Unpacks `zip` into `folder` (which must not exist yet; it is created) and returns the checked app inside it.
    /// `requirement` is the code requirement the app must meet (tests pass a looser one for the later steps).
    public static func prepare(zip: URL, expectedSHA256: String, version: AppVersion, into folder: URL,
                               requirement: String = UpdatePolicy.codeRequirement, limits: Limits = .standard) throws -> URL {
        guard try sha256(of: zip) == expectedSHA256.lowercased() else { throw UpdateError.checksumMismatch }
        let listing = try listEntries(of: zip, limits: limits)
        if let problem = entryProblem(names: listing.names, symlinks: listing.symlinks) { throw UpdateError.badPackage(problem) }
        try unpack(zip, into: folder, limits: limits)
        do {
            // ditto takes names from the local headers, zipinfo from the central directory: what was written must be
            // what was checked.
            if let problem = unpackedTreeProblem(in: folder, listing: listing) { throw UpdateError.badPackage(problem) }
            let app = try locateApp(in: folder)
            try checkBundle(app, version: version, requirement: requirement)
            return app
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The checks on an unpacked (or staged) bundle: no link leading outside it, the release's version, and the code
    /// signature against `requirement`.
    public static func checkBundle(_ app: URL, version: AppVersion, requirement: String = UpdatePolicy.codeRequirement) throws {
        if let link = symlinkEscaping(app) { throw UpdateError.badPackage("the link \u{201C}\(link)\u{201D} points outside the app") }
        try checkVersion(of: app, version: version)
        try UpdateSignature.check(app, requirement: requirement)
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

    /// The zip's entry names, which of them are symlinks and their total unpacked size (`zipinfo`, which only reads
    /// the archive). Throws when the listing, the entry count or the unpacked size is over `limits`.
    public static func listEntries(of archive: URL, limits: Limits = .standard) throws -> Listing {
        let tooLong = UpdateError.badPackage("its listing is too long")
        let names = try runTool("/usr/bin/zipinfo", ["-1", archive.path], maxOutput: limits.maxListingBytes, tooLong: tooLong)
        let long = try runTool("/usr/bin/zipinfo", ["-s", archive.path], maxOutput: limits.maxListingBytes, tooLong: tooLong)
        guard names.status == 0, long.status == 0, let nameText = String(data: names.output, encoding: .utf8),
              let longText = String(data: long.output, encoding: .utf8) else {
            throw UpdateError.badPackage("the zip could not be read")
        }
        let entries = nameText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        guard entries.count <= limits.maxEntries else { throw UpdateError.badPackage("it has too many entries") }
        // In `-s` output, one line per entry starts with a 10-character permission string.
        let lines = longText.split(separator: "\n").map(String.init).filter(isEntryLine)
        guard lines.count == entries.count else { throw UpdateError.badPackage("the zip's entries could not be listed") }
        var symlinks: [String] = []
        var total: Int64 = 0
        for (line, name) in zip(lines, entries) {
            // `-rw-r--r--  2.1 unx  2200 bX defN 26-Nov-15 21:07 name`: the fourth field is the unpacked size.
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard line.hasSuffix(name), fields.count == 5, let size = Int64(fields[3]), size >= 0 else {
                throw UpdateError.badPackage("the zip's entries could not be listed")
            }
            total += size
            guard total <= limits.maxUncompressedBytes else { throw UpdateError.badPackage("it is too large when unpacked") }
            if line.hasPrefix("l") { symlinks.append(name) }
        }
        return Listing(names: entries, symlinks: symlinks, uncompressedBytes: total)
    }

    private static func isEntryLine(_ line: String) -> Bool {
        let permissions = line.prefix(10)
        return permissions.count == 10 && "-dlbcps".contains(permissions.first ?? " ")
            && permissions.dropFirst().allSatisfy { "rwxsStT-".contains($0) }
    }

    /// Why the entries are not one plain `imageconverter.app` folder, or nil: every name inside it, no absolute
    /// path, no `.`/`..`/empty component, no NUL, and nothing written through a symlink entry. Links are compared the
    /// way APFS compares names (ignoring case and Unicode normalisation), so `contents` also covers `Contents/x`.
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
        let links = Set(symlinks.map(folded))
        guard !links.isEmpty else { return nil }
        for name in names {
            // Every proper ancestor of the entry (`a`, `a/b` for `a/b/c`) must not be a link.
            var components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if name.hasSuffix("/") { components.removeLast() }
            for count in stride(from: 1, to: components.count, by: 1) {
                let ancestor = components.prefix(count).joined(separator: "/")
                if links.contains(folded(ancestor)) { return "it writes through the link \u{201C}\(ancestor)\u{201D}" }
            }
        }
        return nil
    }

    /// A name as a case-insensitive, normalisation-insensitive file system compares it, as plain scalars (Swift's
    /// `==` on `String` already treats NFC and NFD alike, but `Set` lookups of the scalars must agree too).
    static func folded(_ name: String) -> String {
        let lower = name.decomposedStringWithCanonicalMapping.lowercased().decomposedStringWithCanonicalMapping
        return String(String.UnicodeScalarView(lower.unicodeScalars))
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

    /// Runs a system tool and returns its exit status and standard output (standard error is discarded). Past
    /// `maxOutput` bytes the tool is stopped and `tooLong` thrown.
    static func runTool(_ path: String, _ arguments: [String], maxOutput: Int = 1 << 20,
                        tooLong: UpdateError = .badPackage("a tool's output was too long")) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.badPackage("\(URL(fileURLWithPath: path).lastPathComponent) could not run") }
        var output = Data()
        let reader = pipe.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
            output.append(chunk)
            if output.count > maxOutput {
                process.terminate()
                process.waitUntilExit()
                throw tooLong
            }
        }
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
