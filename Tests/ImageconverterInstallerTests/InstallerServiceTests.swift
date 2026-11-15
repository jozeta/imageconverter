import XCTest
import ImageconverterCore
@testable import ImageconverterInstallerKit

/// The installer service on temp folders: an `Applications` folder with an installed app holding the service, a fake
/// home with the app's container, ad hoc–signed bundles, and a temp "Trash". No network, no XPC.
final class InstallerServiceTests: XCTestCase {
    private var root: URL!
    private var installed: URL!
    private var service: URL!
    private var home: URL!
    private var trash: URL!
    private let version = AppVersion("9.9.9")!
    private let adHocRequirement = "identifier \"io.github.jozeta.imageconverter\""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        installed = root.appendingPathComponent("Applications/imageconverter.app")
        service = installed.appendingPathComponent("Contents/XPCServices/\(UpdateInstallerService.bundleName)")
        home = root.appendingPathComponent("home")
        trash = root.appendingPathComponent("Trash")
        for folder in [service!, trash!, root.appendingPathComponent("work")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try writeInfo(to: installed, version: "1.0.0")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    private func tool(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func writeInfo(to app: URL, version: String) throws {
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": UpdatePolicy.bundleIdentifier, "CFBundleExecutable": "imageconverter",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    /// An ad hoc–signed `imageconverter.app` of `version`, zipped like a release, placed where the app downloads it.
    private func download(version: String = "9.9.9") throws -> (path: String, sha: String) {
        let source = root.appendingPathComponent("src-\(UUID().uuidString)")
        let app = source.appendingPathComponent("imageconverter.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: app.appendingPathComponent("Contents/MacOS/imageconverter"))
        try writeInfo(to: app, version: version)
        XCTAssertEqual(try tool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", UpdatePolicy.bundleIdentifier,
                                                      app.path]), 0)
        let folder = home.appendingPathComponent("Library/Containers/\(UpdatePolicy.bundleIdentifier)/Data/tmp/"
                                                 + "imageconverter-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("imageconverter-\(version).zip")
        XCTAssertEqual(try tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]), 0)
        return (zip.path, try UpdatePackage.sha256(of: zip))
    }

    private func makeService(requirement: String? = nil, limits: UpdatePackage.Limits = .standard) -> InstallerService {
        var environment = InstallerService.Environment(serviceBundle: service, home: home.path,
                                                       workRoot: root.appendingPathComponent("work"))
        environment.requirement = requirement ?? adHocRequirement
        environment.limits = limits
        environment.operations = TempTrash(trash: trash)
        return InstallerService(environment: environment)
    }

    private var installedVersion: String? {
        let data = try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return info?["CFBundleShortVersionString"] as? String
    }

    private var workFolders: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("work").path)) ?? []
    }

    private func assertRefused(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line)
        XCTAssertEqual(installedVersion, "1.0.0", "the installed app is untouched", file: file, line: line)
        XCTAssertEqual(workFolders, [], "work folder removed", file: file, line: line)
    }

    // MARK: Install

    func testInstallsAndClearsQuarantineAndLeftovers() throws {
        let zip = try download()
        // The sandboxed app's download is quarantined; nothing it carries may reach the installed app.
        let value = Data("0086;00000000;imageconverter;".utf8)
        _ = value.withUnsafeBytes { setxattr(zip.path, UpdateQuarantine.attribute, $0.baseAddress, value.count, 0, 0) }
        let stale = installed.deletingLastPathComponent().appendingPathComponent(".imageconverter-old-1.app")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        try makeService().perform(zipPath: zip.path, expectedSHA256: zip.sha, version: "9.9.9")
        XCTAssertEqual(installedVersion, "9.9.9")
        XCTAssertFalse(UpdateQuarantine.isQuarantined(installed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "stale sibling removed")
        let left = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["imageconverter.app"])
        XCTAssertEqual(workFolders, [])
    }

    func testTheReleaseRequirementRefusesAnAdHocUpdate() throws {
        let zip = try download()
        assertRefused { try makeService(requirement: UpdatePolicy.codeRequirement).perform(zipPath: zip.path, expectedSHA256: zip.sha,
                                                                                          version: "9.9.9") }
    }

    func testRefusesBadArguments() throws {
        let zip = try download()
        let service = makeService()
        assertRefused { try service.perform(zipPath: zip.path, expectedSHA256: String(repeating: "0", count: 64), version: "9.9.9") }
        assertRefused { try service.perform(zipPath: zip.path, expectedSHA256: "abc", version: "9.9.9") }
        assertRefused { try service.perform(zipPath: zip.path, expectedSHA256: zip.sha, version: "9.9") }
        assertRefused { try service.perform(zipPath: zip.path, expectedSHA256: zip.sha, version: "9.9.8") }
    }

    func testRefusesAZipOutsideTheAppsDownloadFolder() throws {
        let zip = try download()
        let elsewhere = root.appendingPathComponent("imageconverter-9.9.9.zip")
        try FileManager.default.copyItem(atPath: zip.path, toPath: elsewhere.path)
        assertRefused { try makeService().perform(zipPath: elsewhere.path, expectedSHA256: zip.sha, version: "9.9.9") }
    }

    func testRefusesASymlinkedZip() throws {
        let zip = try download()
        let real = root.appendingPathComponent("real.zip")
        try FileManager.default.moveItem(atPath: zip.path, toPath: real.path)
        try FileManager.default.createSymbolicLink(atPath: zip.path, withDestinationPath: real.path)
        assertRefused { try makeService().perform(zipPath: zip.path, expectedSHA256: zip.sha, version: "9.9.9") }
    }

    func testRefusesAZipOverTheListingCaps() throws {
        let zip = try download()
        let small = UpdatePackage.Limits(maxEntries: 20_000, maxUncompressedBytes: 1000, maxListingBytes: 8 << 20)
        assertRefused { try makeService(limits: small).perform(zipPath: zip.path, expectedSHA256: zip.sha, version: "9.9.9") }
    }

    func testRefusesWhenTheServiceIsNotInsideAnApp() throws {
        let zip = try download()
        var environment = InstallerService.Environment(serviceBundle: root.appendingPathComponent("loose.xpc"), home: home.path,
                                                       workRoot: root.appendingPathComponent("work"))
        environment.requirement = adHocRequirement
        environment.operations = TempTrash(trash: trash)
        assertRefused { try InstallerService(environment: environment).perform(zipPath: zip.path, expectedSHA256: zip.sha,
                                                                                version: "9.9.9") }
    }

    func testOneInstallAtATimeAndRepliesOverTheProtocol() throws {
        let zip = try download()
        let service = makeService()
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        var replies: [String?] = []
        service.install(zipPath: zip.path, expectedSHA256: zip.sha, version: "9.9.9") { replies.append($0); first.fulfill() }
        service.install(zipPath: zip.path, expectedSHA256: zip.sha, version: "9.9.9") { message in
            XCTAssertEqual(message, "An update is already being installed.")
            second.fulfill()
        }
        wait(for: [second, first], timeout: 30)
        XCTAssertEqual(replies, [nil])
        XCTAssertEqual(installedVersion, "9.9.9")
    }

    // MARK: Pure rules

    func testTargetAppComesFromTheServicesOwnLocation() {
        let name = UpdateInstallerService.bundleName
        let inside = URL(fileURLWithPath: "/Applications/imageconverter.app/Contents/XPCServices/\(name)")
        XCTAssertEqual(InstallRequest.targetApp(forService: inside)?.path, "/Applications/imageconverter.app")
        for bad in ["/tmp/\(name)", "/Applications/Folder/Contents/XPCServices/\(name)", "/Applications/x.app/Contents/Helpers/\(name)",
                    "/Applications/x.app/XPCServices/\(name)", "/Applications/x.app/Contents/XPCServices/service"] {
            XCTAssertNil(InstallRequest.targetApp(forService: URL(fileURLWithPath: bad)), bad)
        }
    }

    func testZipPathRules() {
        let id = UpdatePolicy.bundleIdentifier
        let uuid = UUID().uuidString
        let tmp = "/Users/u/Library/Containers/\(id)/Data/tmp"
        let good = "\(tmp)/imageconverter-update-\(uuid)/imageconverter-9.9.9.zip"
        XCTAssertNil(InstallRequest.zipPathProblem(good, home: "/Users/u", clientBundleID: id, version: version))
        let bad = [
            "\(tmp)/imageconverter-update-\(uuid)/imageconverter-9.9.8.zip",
            "\(tmp)/imageconverter-update-nope/imageconverter-9.9.9.zip",
            "\(tmp)/imageconverter-update-\(uuid)/x/imageconverter-9.9.9.zip",
            "\(tmp)/imageconverter-9.9.9.zip",
            "\(tmp)/imageconverter-update-\(uuid)/../imageconverter-update-\(uuid)/imageconverter-9.9.9.zip",
            "/Users/u/Library/Containers/other.app/Data/tmp/imageconverter-update-\(uuid)/imageconverter-9.9.9.zip",
            "/tmp/imageconverter-update-\(uuid)/imageconverter-9.9.9.zip",
            "imageconverter-9.9.9.zip",
        ]
        for path in bad {
            XCTAssertNotNil(InstallRequest.zipPathProblem(path, home: "/Users/u", clientBundleID: id, version: version), path)
        }
        XCTAssertNotNil(InstallRequest.zipPathProblem(good, home: "/Users/u", clientBundleID: "", version: version))
    }

    func testClientRequirementIsTheDeveloperIDUnlessBuiltForTheEndToEndTest() {
        #if UPDATE_E2E
        XCTAssertEqual(InstallerPolicy.clientRequirement, "identifier \"io.github.jozeta.imageconverter.updatetest\"")
        #else
        XCTAssertEqual(InstallerPolicy.clientRequirement, "anchor apple generic and identifier \"io.github.jozeta.imageconverter\" "
            + "and certificate leaf[subject.OU] = \"6W6TD6P8G3\"")
        #endif
    }
}

/// The real operations, except that the "Trash" is a temp folder.
private struct TempTrash: UpdateFileOperations {
    let trash: URL
    private let system = SystemUpdateFileOperations()

    func copy(_ source: URL, to destination: URL) throws { try system.copy(source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try system.move(source, to: destination) }
    func remove(_ url: URL) throws { try system.remove(url) }
    func trash(_ url: URL) throws { try system.move(url, to: trash.appendingPathComponent(url.lastPathComponent)) }
}
