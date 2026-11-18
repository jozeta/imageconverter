import Foundation

/// What is going on when the user quits: a manual batch, job runs, Shortcuts actions (running or waiting for their
/// turn), and an update install (from the installer service call's start until it returns).
public struct RunningWork: Equatable, Sendable {
    public var manualBatch: Bool
    public var jobs: Int
    public var actions: Int
    public var installingUpdate: Bool

    public init(manualBatch: Bool = false, jobs: Int = 0, actions: Int = 0, installingUpdate: Bool = false) {
        self.manualBatch = manualBatch
        self.jobs = jobs
        self.actions = actions
        self.installingUpdate = installingUpdate
    }

    public var anything: Bool { manualBatch || jobs > 0 || actions > 0 || installingUpdate }
}

/// The question the app asks before quitting.
public struct QuitQuestion: Equatable, Sendable {
    public let title: String
    public let message: String
    /// The button that stops everything and quits; nil while an update is installing (D1): the installer service
    /// is replacing the app then, so only waiting is offered.
    public let stopButton: String?
    /// Keeps the app running (the default button; also Escape).
    public let cancelButton: String
}

public enum QuitPolicy {
    /// nil: nothing is running, the app quits at once.
    public static func question(for work: RunningWork) -> QuitQuestion? {
        guard work.anything else { return nil }
        if work.installingUpdate {
            return QuitQuestion(
                title: "An update is being installed",
                message: "imageconverter is replacing itself with the new version. Quitting now could leave no app "
                    + "in its place. When the update is in place imageconverter opens again by itself (or says what "
                    + "went wrong); quit after that.",
                stopButton: nil, cancelButton: "Wait")
        }
        return QuitQuestion(title: "Stop and quit?",
                            message: message(manual: work.manualBatch, jobs: work.jobs, actions: work.actions),
                            stopButton: "Stop and Quit", cancelButton: "Cancel")
    }

    static func message(manual: Bool, jobs: Int, actions: Int) -> String {
        var running: [String] = []
        if manual { running.append("a batch") }
        if jobs > 0 { running.append(jobs == 1 ? "a job" : "\(jobs) jobs") }
        if actions > 0 { running.append(actions == 1 ? "a Shortcuts action" : "\(actions) Shortcuts actions") }
        let list = running.count > 2 ? running.dropLast().joined(separator: ", ") + " and " + (running.last ?? "")
            : running.joined(separator: " and ")
        return "imageconverter is converting \(list). Files already written are kept; "
            + "the rest is not converted. Nothing half-written is left behind."
    }
}

/// Whether the update installer service is working right now: set for exactly as long as `perform`'s body (the
/// one XPC call) runs, also when it throws. Quitting asks while it is set (`RunningWork.installingUpdate`).
@MainActor
public final class InstallActivity {
    private var depth = 0

    public init() {}

    public var isInstalling: Bool { depth > 0 }

    public func perform<T>(_ body: () async throws -> T) async rethrows -> T {
        depth += 1
        defer { depth -= 1 }
        return try await body()
    }
}
