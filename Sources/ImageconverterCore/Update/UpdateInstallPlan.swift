import Foundation

/// Pure decisions around updating.
public enum UpdateInstallPlan {
    public enum InstallDecision: Equatable, Sendable {
        case allowed
        case refused(String)
    }

    public enum LaunchCheck: Equatable, Sendable {
        case ask, check, skip
    }

    /// Installing needs the packaged app and no running batch or job.
    public static func canInstall(isBundle: Bool, isRunning: Bool) -> InstallDecision {
        if !isBundle { return .refused("Updates install only in the released app.") }
        if isRunning { return .refused("Finish the running batch or job first.") }
        return .allowed
    }

    /// Why the app can't replace itself where it is, or nil: macOS runs it from a read-only, randomised copy
    /// (App Translocation, a quarantined app opened where it was downloaded) or from a read-only volume (a disk image).
    public static func locationProblem(appPath: String, isReadOnlyVolume: Bool) -> String? {
        guard appPath.contains("/AppTranslocation/") || isReadOnlyVolume else { return nil }
        return "imageconverter is running from a read-only location, so it can't update itself. Move it to your "
            + "Applications folder, open it from there and try again."
    }

    /// `answer` is the stored "check when the app starts" choice, nil until the user answered.
    public static func shouldCheckOnLaunch(answer: Bool?) -> LaunchCheck {
        switch answer {
        case nil: .ask
        case true?: .check
        case false?: .skip
        }
    }
}
