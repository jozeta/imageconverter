import XCTest
@testable import ImageconverterCore

/// Review focus 2: a tampered or broken update zip is refused and its unpack folder deleted. Bundles are built
/// in temp folders (a copy of `/usr/bin/true` as the executable) and signed ad hoc; no network.
final class UpdatePackageTests: XCTestCase {
    private var root: URL!
    private let version = AppVersion("9.9.9")!
    /// Accepts an ad hoc signature with the right identifier, so the steps after the signature can be tested.
    private let adHocRequirement = "identifier \"io.github.jozeta.imageconverter\""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("update-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    private func tool(_ path: String, _ arguments: [String], in directory: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// `<folder>/<name>`: a minimal app bundle with `version`, optionally signed ad hoc.
    @discardableResult
    private func makeApp(in folder: URL, name: String = "imageconverter.app", version: String = "9.9.9",
                         sign: Bool = true, links: [String: String] = [:]) throws -> URL {
        let app = folder.appendingPathComponent(name)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: macOS.appendingPathComponent("imageconverter"))
        let info: [String: Any] = ["CFBundleIdentifier": UpdatePolicy.bundleIdentifier, "CFBundleExecutable": "imageconverter",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        for (path, target) in links {
            let link = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        if sign {
            let status = try tool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", UpdatePolicy.bundleIdentifier,
                                                         app.path])
            XCTAssertEqual(status, 0, "codesign failed")
        }
        return app
    }

    /// Zips `app` the way `release.sh` does (`ditto -c -k --keepParent`).
    private func zip(_ app: URL, keepParent: Bool = true) throws -> URL {
        let zip = root.appendingPathComponent("\(UUID().uuidString).zip")
        let arguments = keepParent ? ["-c", "-k", "--keepParent", app.path, zip.path] : ["-c", "-k", app.path, zip.path]
        XCTAssertEqual(try tool("/usr/bin/ditto", arguments), 0)
        return zip
    }

    private func source(_ name: String = "src") throws -> URL {
        let folder = root.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var unpackFolder: URL { root.appendingPathComponent("unpack") }

    private func prepare(_ zip: URL, sha: String? = nil, version: AppVersion? = nil,
                         requirement: String = UpdatePolicy.codeRequirement) throws -> URL {
        try UpdatePackage.prepare(zip: zip, expectedSHA256: sha ?? UpdatePackage.sha256(of: zip), version: version ?? self.version,
                                  into: unpackFolder, requirement: requirement)
    }

    private func assertRefused(_ zip: URL, sha: String? = nil, version: AppVersion? = nil,
                               requirement: String = UpdatePolicy.codeRequirement,
                               file: StaticString = #filePath, line: UInt = #line, _ check: (UpdateError) -> Bool) {
        XCTAssertThrowsError(try prepare(zip, sha: sha, version: version, requirement: requirement), file: file, line: line) { error in
            guard let error = error as? UpdateError else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(check(error), "\(error)", file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpackFolder.path), "unpack folder left behind", file: file, line: line)
    }

    // MARK: Signature

    func testAdHocSignedAppIsRefusedByTheReleaseRequirement() throws {
        let app = try makeApp(in: try source())
        assertRefused(try zip(app)) { $0 == .signatureRejected }
        XCTAssertThrowsError(try UpdateSignature.check(app, requirement: UpdatePolicy.codeRequirement))
    }

    func testUnsignedAppIsRefused() throws {
        let app = try makeApp(in: try source(), sign: false)
        assertRefused(try zip(app), requirement: adHocRequirement) { $0 == .signatureRejected }
    }

    func testValidPackageIsUnpackedAndChecked() throws {
        let app = try makeApp(in: try source(), links: ["Contents/Resources/inside": "../MacOS/imageconverter"])
        let unpacked = try prepare(try zip(app), requirement: adHocRequirement)
        XCTAssertEqual(unpacked, unpackFolder.appendingPathComponent("imageconverter.app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("Contents/Info.plist").path))
    }

    func testAppModifiedAfterSigningIsRefused() throws {
        let app = try makeApp(in: try source())
        // Info.plist is bound into the signature; a trailing newline still parses but breaks the seal.
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try (try Data(contentsOf: plist) + Data("\n".utf8)).write(to: plist)
        assertRefused(try zip(app), requirement: adHocRequirement) { $0 == .signatureRejected }
    }

    // MARK: Checksum, layout, links, version

    func testChecksumMismatchIsRefused() throws {
        let app = try makeApp(in: try source())
        assertRefused(try zip(app), sha: String(repeating: "0", count: 64), requirement: adHocRequirement) { $0 == .checksumMismatch }
    }

    func testTwoAppsAreRefused() throws {
        let folder = try source()
        try makeApp(in: folder)
        try makeApp(in: folder, name: "other.app")
        assertRefused(try zip(folder, keepParent: false), requirement: adHocRequirement) {
            if case .badPackage = $0 { return true } else { return false }
        }
    }

    func testWronglyNamedAppIsRefused() throws {
        let app = try makeApp(in: try source(), name: "Imageconverter Pro.app")
        assertRefused(try zip(app), requirement: adHocRequirement) {
            if case .badPackage = $0 { return true } else { return false }
        }
    }

    func testSymlinkOutsideTheBundleIsRefused() throws {
        for target in ["/etc", "../../../outside", "../../.."] {
            let app = try makeApp(in: try source(), sign: false, links: ["Contents/Resources/link": target])
            assertRefused(try zip(app), requirement: adHocRequirement) {
                if case .badPackage(let reason) = $0 { return reason.contains("link") } else { return false }
            }
        }
    }

    func testVersionMismatchIsRefused() throws {
        let app = try makeApp(in: try source(), version: "9.9.8")
        assertRefused(try zip(app), requirement: adHocRequirement) { $0 == .versionMismatch }
    }

    func testNotAZipIsRefused() throws {
        let file = root.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: file)
        assertRefused(file, requirement: adHocRequirement) {
            if case .badPackage = $0 { return true } else { return false }
        }
    }

    func testUnpackFolderMustBeNew() throws {
        let app = try makeApp(in: try source())
        try FileManager.default.createDirectory(at: unpackFolder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try prepare(try zip(app), requirement: adHocRequirement))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpackFolder.path), "an existing folder is not ours to delete")
    }

    // MARK: Zip entries (checked before anything is unpacked)

    func testEntryNameRules() {
        let valid = ["imageconverter.app/", "imageconverter.app/Contents/", "imageconverter.app/Contents/Info.plist"]
        XCTAssertNil(UpdatePackage.entryProblem(names: valid, symlinks: []))
        for bad in ["../escape", "/etc/passwd", "imageconverter.app/../../escape", "other.app/x", "imageconverter.appx/y",
                    "imageconverter.app//x", "imageconverter.app/./x", "imageconverter.app/a\u{0}b"] {
            XCTAssertNotNil(UpdatePackage.entryProblem(names: valid + [bad], symlinks: []), bad)
        }
        XCTAssertNotNil(UpdatePackage.entryProblem(names: [], symlinks: []), "empty zip")
        // A file written through a symlink entry.
        let link = "imageconverter.app/Contents/link"
        XCTAssertNotNil(UpdatePackage.entryProblem(names: valid + [link, link + "/x"], symlinks: [link]))
        XCTAssertNil(UpdatePackage.entryProblem(names: valid + [link], symlinks: [link]))
    }

    func testZipListingOfARealZip() throws {
        let app = try makeApp(in: try source(), sign: false, links: ["Contents/my link": "MacOS/imageconverter"])
        let listing = try UpdatePackage.listEntries(of: try zip(app))
        XCTAssertTrue(listing.names.contains("imageconverter.app/Contents/Info.plist"))
        XCTAssertEqual(listing.symlinks, ["imageconverter.app/Contents/my link"])
    }

    func testSHA256() throws {
        let file = root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UpdatePackage.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
