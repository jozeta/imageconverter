import AppKit
import ImageconverterCore

/// Hands a downloaded update to the installer XPC service inside the bundle and relaunches. The service is not
/// sandboxed (files the sandboxed app unpacks would be quarantined and couldn't be opened): it re-checks everything
/// and swaps the app (see `InstallerService`). `prepare` runs before anything is downloaded: refused outside the
/// released app bundle (or without the service), while a batch or job runs, and from a translocated or read-only
/// location. "Nothing running" is checked again right before the service is called.
@MainActor
enum UpdateInstaller {
    static var installedApp: URL { Bundle.main.bundleURL }
    static var isBundle: Bool { installedApp.pathExtension == "app" }
    static var serviceURL: URL {
        installedApp.appendingPathComponent("Contents/XPCServices/\(UpdateInstallerService.bundleName)", isDirectory: true)
    }

    /// Throws `UpdateError.installRefused` when it may not install now.
    static func checkAllowed(isRunning: Bool) throws {
        let hasService = FileManager.default.fileExists(atPath: serviceURL.path)
        if case .refused(let reason) = UpdateInstallPlan.canInstall(isBundle: isBundle && hasService, isRunning: isRunning) {
            throw UpdateError.installRefused(reason)
        }
    }

    /// Everything the app can decide before downloading.
    static func prepare(isRunning: () -> Bool) throws {
        try checkAllowed(isRunning: isRunning())
        let installed = installedApp
        let readOnly = (try? installed.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if let problem = UpdateInstallPlan.locationProblem(appPath: installed.path, isReadOnlyVolume: readOnly) {
            throw UpdateError.installRefused(problem)
        }
    }

    /// Asks the service to install `zip` (in the app's container). Throws with the service's message on refusal.
    static func install(zip: URL, sha256: String, version: AppVersion, isRunning: () -> Bool) async throws {
        try checkAllowed(isRunning: isRunning())
        let message = try await callService { service, reply in
            service.install(zipPath: zip.path, expectedSHA256: sha256, version: version.description, reply: reply)
        }
        if let message { throw UpdateError.installRefused(message) }
    }

    /// Removes what an interrupted install left (the service's folders, hidden siblings next to the app). Best effort.
    static func cleanUp() {
        guard isBundle, FileManager.default.fileExists(atPath: serviceURL.path) else { return }
        Task { _ = try? await callService { service, reply in service.cleanUp { reply(nil) } } }
    }

    /// How long the app waits for the service before giving up (a 200 MB unpack and check takes far less).
    static let serviceTimeout: Duration = .seconds(600)

    /// One call to the service; the reply, the connection error or the timeout ends it (exactly once). On a timeout
    /// the connection is invalidated.
    private static func callService(_ body: @escaping (UpdateInstallerProtocol, @escaping (String?) -> Void) -> Void)
        async throws -> String? {
        let connection = NSXPCConnection(serviceName: UpdateInstallerService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: UpdateInstallerProtocol.self)
        connection.resume()
        let once = Once()
        defer {
            once.timer?.cancel()
            connection.invalidate()
        }
        return try await withCheckedThrowingContinuation { continuation in
            once.timer = Task {
                try? await Task.sleep(for: serviceTimeout)
                if once.claim() {
                    connection.invalidate()
                    continuation.resume(throwing: UpdateError.installFailed("the installer didn't answer in time. "
                        + "Quit and open imageconverter, then try again."))
                }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                if once.claim() {
                    continuation.resume(throwing: UpdateError.installFailed("the installer could not be reached "
                        + "(\(error.localizedDescription))."))
                }
            }
            guard let service = proxy as? UpdateInstallerProtocol else {
                if once.claim() { continuation.resume(throwing: UpdateError.installFailed("the installer could not be reached.")) }
                return
            }
            body(service) { message in
                if once.claim() { continuation.resume(returning: message) }
            }
        }
    }

    /// Opens the app now at the installed path as a new instance, then quits this one. Nothing runs (installing
    /// was refused otherwise), so `QuitCoordinator` lets it quit at once.
    static func relaunch(onFailure: @escaping @MainActor (String) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: installedApp, configuration: configuration) { _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message {
                    onFailure("The update is installed, but it could not be opened (\(message)). Quit and open imageconverter again.")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// True for the first caller only (a reply and a connection error can race).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// The timeout, cancelled once the call ended.
    var timer: Task<Void, Never>? {
        get { lock.withLock { storedTimer } }
        set { lock.withLock { storedTimer = newValue } }
    }
    private var storedTimer: Task<Void, Never>?

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
