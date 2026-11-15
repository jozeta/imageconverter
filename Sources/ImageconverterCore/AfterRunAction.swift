import Foundation

/// What the app does when a run finishes (an app-wide setting, not part of a preset).
public enum AfterRunAction: String, CaseIterable, Sendable, Codable {
    case nothing, reveal, notify, revealAndNotify

    public var revealsInFinder: Bool { self == .reveal || self == .revealAndNotify }
    public var notifies: Bool { self == .notify || self == .revealAndNotify }

    public var label: String {
        switch self {
        case .nothing: return "Nothing"
        case .reveal: return "Reveal in Finder"
        case .notify: return "Notify me"
        case .revealAndNotify: return "Reveal and notify"
        }
    }

    /// The notification for a finished run: "Run cancelled · converted N", "No images converted · N failed", or
    /// "Run finished" with `summary` (`RunCountsText.runSummary`). Failed extra outputs are added to the first two;
    /// the summary already names them.
    public static func notification(for report: BatchReport, summary: String) -> (title: String, body: String) {
        let extras = report.extraFailures.isEmpty ? "" : " · " + RunCountsText.extraFailures(report.extraFailures.count)
        if report.cancelled { return ("Run cancelled", "Run cancelled · converted \(report.convertedCount)\(extras)") }
        if report.written.isEmpty {
            return ("Run finished", "No images converted · \(report.failures.count) failed\(extras)")
        }
        return ("Run finished", summary)
    }

    /// Most files selected in Finder; with more, the folders that hold them are revealed instead.
    public static let maxRevealedFiles = 50

    /// What to do for a run that wrote `written`: the URLs to select in Finder (the files, or their unique folders
    /// in first-seen order when there are more than `maxRevealedFiles`) and whether to post a notification (only
    /// when the app isn't frontmost, since the result is on screen otherwise). A run that wrote nothing never reveals,
    /// and notifies only when files failed.
    public func plan(written: [URL], failed: Int = 0, appIsActive: Bool) -> (reveal: [URL], notify: Bool) {
        // Nothing written: no Finder window, but a backgrounded user still hears that files failed.
        guard !written.isEmpty else { return ([], notifies && failed > 0 && !appIsActive) }
        var reveal: [URL] = []
        if revealsInFinder {
            if written.count <= Self.maxRevealedFiles {
                reveal = written
            } else {
                var seen = Set<String>()
                for url in written {
                    let folder = url.deletingLastPathComponent()
                    if seen.insert(folder.standardizedFileURL.path).inserted { reveal.append(folder) }
                }
            }
        }
        return (reveal, notifies && !appIsActive)
    }
}
