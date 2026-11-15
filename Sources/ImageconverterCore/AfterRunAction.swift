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

    /// Most files selected in Finder; with more, the folders that hold them are revealed instead.
    public static let maxRevealedFiles = 50

    /// What to do for a run that wrote `written`: the URLs to select in Finder (the files, or their unique folders
    /// in first-seen order when there are more than `maxRevealedFiles`) and whether to post a notification (only
    /// when the app isn't frontmost, since the result is on screen otherwise). A run that wrote nothing does neither.
    public func plan(written: [URL], appIsActive: Bool) -> (reveal: [URL], notify: Bool) {
        guard !written.isEmpty else { return ([], false) }
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
