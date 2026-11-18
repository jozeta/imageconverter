import Foundation

/// What starting a run in the app did.
public enum RunStart: Equatable, Sendable {
    case started
    /// A run is already going (or there was nothing to run).
    case busy
    /// Sandbox: the user didn't allow a folder the run needs.
    case noAccess
}

/// What the app does when Resume's run didn't start (C5): the interrupted batch stays (its journal on disk and
/// the question), and a toast says why, instead of losing the batch's own pipeline and output mode silently.
public struct ResumeStart: Equatable, Sendable {
    public let keepsInterruptedRun: Bool
    /// Shown again at once, so Resume can be pressed again.
    public let asksAgain: Bool
    public let toastTitle: String?
    public let toastDescription: String?

    public static func after(_ start: RunStart) -> ResumeStart {
        switch start {
        case .started:
            return ResumeStart(keepsInterruptedRun: false, asksAgain: false, toastTitle: nil, toastDescription: nil)
        case .busy:
            return kept(because: "Another conversion started first.")
        case .noAccess:
            return kept(because: "imageconverter wasn't allowed to use a folder the batch needs.")
        }
    }

    private static func kept(because reason: String) -> ResumeStart {
        ResumeStart(keepsInterruptedRun: true, asksAgain: true, toastTitle: "The interrupted batch didn't start",
                    toastDescription: reason + " It's kept with its own pipeline and output: choose Resume again, "
                        + "or Not Now to be asked at the next launch.")
    }
}
