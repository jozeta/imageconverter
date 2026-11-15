import AppKit
import ImageconverterCore

/// Puts a checked new app in place of the running one and relaunches. `prepare` runs before anything is downloaded:
/// refused outside the released app bundle, while a batch or job runs (`UpdateInstallPlan`), from a translocated or
/// read-only location, or when the folder holding the app can't be written (in the sandbox it is asked for once with
/// a pre-filled open panel and kept as a folder grant, `AccessStore`). `install` stages the verified app beside the
/// installed one and checks the staged copy again, asks "is anything running?" once more, then swaps
/// (`UpdateReplacer`: the old app goes to the Trash only after the new one is in place).
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

    /// Everything that can be decided before downloading: may install, a location that can be changed, folder access
    /// and write permission. `isRunning` is asked before and again after the access question.
    static func prepare(isRunning: () -> Bool) throws {
        try checkAllowed(isRunning: isRunning())
        let installed = installedApp
        let readOnly = (try? installed.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if let problem = UpdateInstallPlan.locationProblem(appPath: installed.path, isReadOnlyVolume: readOnly) {
            throw UpdateError.installRefused(problem)
        }
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
    }

    /// Replaces the installed app with `verified` (of `version`). Returns a note when the old version couldn't be
    /// removed afterwards.
    static func install(_ verified: URL, version: AppVersion, isRunning: () -> Bool) async throws -> String? {
        try checkAllowed(isRunning: isRunning())
        let installed = installedApp
        let staged = try await Task.detached(priority: .userInitiated) {
            try UpdateReplacer.stage(verified, beside: installed) { try UpdatePackage.checkBundle($0, version: version) }
        }.value
        do {
            try checkAllowed(isRunning: isRunning())
        } catch {
            UpdateReplacer.discard(staged)
            throw error
        }
        return try await Task.detached(priority: .userInitiated) {
            try UpdateReplacer.swap(installed, with: staged)
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
