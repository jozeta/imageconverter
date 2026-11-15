import AppKit
import ImageconverterCore

/// Puts a checked new app in place of the running one and relaunches. Refused outside the released app bundle and
/// while a batch or job runs (`UpdateInstallPlan`, checked again right before anything moves). The folder holding
/// the app must be writable: in the sandbox it is asked for once with a pre-filled open panel and kept as a folder
/// grant (`AccessStore`). The swap itself is `UpdateReplacer` (old app to the Trash, new one in, old one restored on
/// failure).
@MainActor
enum UpdateInstaller {
    static var installedApp: URL { Bundle.main.bundleURL }
    static var isBundle: Bool { installedApp.pathExtension == "app" }

    /// Throws `UpdateError.installRefused` when it may not install now.
    static func checkAllowed(isRunning: Bool) throws {
        if case .refused(let reason) = UpdateInstallPlan.canInstall(isBundle: isBundle, isRunning: isRunning) {
            throw UpdateError.installRefused(reason)
        }
    }

    /// Replaces the installed app with `newApp`. `isRunning` is asked before and again after the access question.
    static func install(_ newApp: URL, isRunning: () -> Bool) async throws {
        try checkAllowed(isRunning: isRunning())
        let installed = installedApp
        let folder = installed.deletingLastPathComponent()
        guard AccessStore.shared.ensureAccess(toFolder: folder, purpose: .installUpdate) else {
            throw UpdateError.installRefused("Not installed: imageconverter needs access to \u{201C}\(folder.lastPathComponent)\u{201D} "
                + "to replace the app.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError.installRefused("Not installed: you can't change \u{201C}\(folder.lastPathComponent)\u{201D}. "
                + "Download the update from the release page and install it by hand.")
        }
        try checkAllowed(isRunning: isRunning())
        try await Task.detached(priority: .userInitiated) {
            try UpdateReplacer.replace(installed, with: newApp)
        }.value
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
