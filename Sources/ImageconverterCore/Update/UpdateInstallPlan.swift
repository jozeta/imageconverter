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

    /// `answer` is the stored "check when the app starts" choice, nil until the user answered.
    public static func shouldCheckOnLaunch(answer: Bool?) -> LaunchCheck {
        switch answer {
        case nil: .ask
        case true?: .check
        case false?: .skip
        }
    }
}
