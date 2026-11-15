import Foundation
import ImageconverterCore

/// The installer service's work. Runs outside the App Sandbox, so the files it unpacks aren't quarantined; it trusts
/// nothing the app sends: the app to replace is the one containing the service, the zip must be the app's download,
/// and every check (size, SHA-256, listing caps, watched unpack, layout, links, version, Developer ID + notarized
/// signature) is done again on its own copy. One install at a time.
public final class InstallerService: NSObject, UpdateInstallerProtocol, @unchecked Sendable {
    public struct Environment {
        /// The service's own bundle (`…/imageconverter.app/Contents/XPCServices/….xpc`).
        public var serviceBundle: URL
        public var home: String
        /// Where the service makes its work folders.
        public var workRoot: URL
        /// What the downloaded app must meet (tests pass a looser one).
        public var requirement: String = UpdatePolicy.codeRequirement
        public var limits: UpdatePackage.Limits = .standard
        public var operations: UpdateFileOperations = SystemUpdateFileOperations()

        public init(serviceBundle: URL, home: String, workRoot: URL) {
            self.serviceBundle = serviceBundle
            self.home = home
            self.workRoot = workRoot
        }

        public static var live: Environment {
            Environment(serviceBundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser.path,
                        workRoot: FileManager.default.temporaryDirectory)
        }
    }

    private let environment: Environment
    private let lock = NSLock()
    private var busy = false
    private let queue = DispatchQueue(label: "io.github.jozeta.imageconverter.installer")

    public init(environment: Environment) {
        self.environment = environment
    }

    // MARK: XPC

    public func install(zipPath: String, expectedSHA256: String, version: String, reply: @escaping (String?) -> Void) {
        guard begin() else { return reply("An update is already being installed.") }
        queue.async {
            defer { self.end() }
            do {
                try self.perform(zipPath: zipPath, expectedSHA256: expectedSHA256, version: version)
                reply(nil)
            } catch {
                reply((error as? UpdateError)?.message ?? error.localizedDescription)
            }
        }
    }

    public func cleanUp(reply: @escaping () -> Void) {
        queue.async {
            self.removeWorkFolders()
            if let target = InstallRequest.targetApp(forService: self.environment.serviceBundle) {
                UpdateReplacer.removeLeftovers(beside: target, using: self.environment.operations)
            }
            reply()
        }
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    private func end() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    // MARK: Work

    /// The whole install, synchronously. Throws `UpdateError`s whose `message` is shown to the user.
    public func perform(zipPath: String, expectedSHA256: String, version versionText: String) throws {
        guard let version = AppVersion(versionText) else { throw UpdateError.noSuitableRelease }
        guard InstallRequest.isSHA256(expectedSHA256) else { throw UpdateError.badChecksumFile }
        guard let target = InstallRequest.targetApp(forService: environment.serviceBundle) else {
            throw UpdateError.installRefused("Updates install only in the released app.")
        }
        let readOnly = (try? target.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if let problem = UpdateInstallPlan.locationProblem(appPath: target.path, isReadOnlyVolume: readOnly) {
            throw UpdateError.installRefused(problem)
        }
        let clientID = Self.bundleIdentifier(of: target) ?? ""
        if let problem = InstallRequest.zipPathProblem(zipPath, home: environment.home, clientBundleID: clientID, version: version) {
            throw UpdateError.installRefused(problem)
        }
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError.installRefused("Not installed: you can't change \u{201C}\(folder.lastPathComponent)\u{201D}. "
                + "Download the update from the release page and install it by hand.")
        }

        let work = environment.workRoot.appendingPathComponent(InstallerPolicy.workFolderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent(UpdatePolicy.zipName(for: version))
        try InstallRequest.copyZip(at: zipPath, to: zip, maxBytes: UpdatePolicy.maxZipBytes)
        let app = try UpdatePackage.prepare(zip: zip, expectedSHA256: expectedSHA256, version: version,
                                            into: work.appendingPathComponent("unpacked", isDirectory: true),
                                            requirement: environment.requirement, limits: environment.limits)

        UpdateReplacer.removeLeftovers(beside: target, using: environment.operations)
        let requirement = environment.requirement
        let staged = try UpdateReplacer.stage(app, beside: target, using: environment.operations) {
            try UpdatePackage.checkBundle($0, version: version, requirement: requirement)
        }
        do {
            try UpdateQuarantine.strip(staged)
        } catch {
            UpdateReplacer.discard(staged, using: environment.operations)
            throw error
        }
        _ = try UpdateReplacer.swap(target, with: staged, using: environment.operations)
        if UpdateQuarantine.isQuarantined(target) { try UpdateQuarantine.strip(target) }
    }

    private func removeWorkFolders() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: environment.workRoot.path)) ?? []
        for name in names where name.hasPrefix(InstallerPolicy.workFolderPrefix) {
            try? FileManager.default.removeItem(at: environment.workRoot.appendingPathComponent(name))
        }
    }

    static func bundleIdentifier(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), data.count <= 1_000_000,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
}

/// Accepts connections only from a client meeting `InstallerPolicy.clientRequirement`.
public final class InstallerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: InstallerService

    public init(service: InstallerService) {
        self.service = service
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(InstallerPolicy.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: UpdateInstallerProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
