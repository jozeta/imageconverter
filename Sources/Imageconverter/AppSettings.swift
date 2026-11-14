import Foundation
import Observation
import ImageconverterCore

/// User preferences for where converted files go, persisted in `UserDefaults`.
///
/// The output folder is stored as a path and a bookmark (`outputFolderBookmark`), so the sandboxed app can open it
/// again after a relaunch: the bookmark is resolved at launch (a moved folder is followed) and access stays started.
/// When it no longer resolves, the run asks for the folder again (`AccessStore.ensureAccess`).
@MainActor @Observable
final class AppSettings {
    private enum Key {
        static let modeKind = "outputModeKind"
        static let folder = "outputFolder"
        static let folderBookmark = "outputFolderBookmark"
        static let suffix = "sameFolderSuffix"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var modeKind: OutputModeKind {
        didSet { defaults.set(modeKind.rawValue, forKey: Key.modeKind) }
    }

    var outputFolder: URL? {
        didSet {
            defaults.set(outputFolder?.path, forKey: Key.folder)
            // Made now, while the app has access (the folder was just chosen in a panel). Also when the same folder
            // is chosen again: that replaces a bookmark that no longer opens it.
            let bookmark = outputFolder.flatMap(FolderAccess.usableBookmark)
            let same = outputFolder == oldValue
            if same && bookmark == nil { return }    // nothing better than what is stored
            defaults.set(bookmark, forKey: Key.folderBookmark)
            if !same { outputAccess = nil }
            if let outputFolder, bookmark != nil { AccessStore.shared.addSessionRoot(outputFolder) }
        }
    }
    /// Access started on the resolved output folder bookmark at launch.
    @ObservationIgnored private var outputAccess: FolderAccess.Grant?

    var sameFolderSuffix: String {
        didSet { defaults.set(sameFolderSuffix, forKey: Key.suffix) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        modeKind = defaults.string(forKey: Key.modeKind).flatMap(OutputModeKind.init(rawValue:)) ?? .newFolder
        outputFolder = defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        sameFolderSuffix = defaults.string(forKey: Key.suffix) ?? OutputPlanner.defaultSuffix
        restoreOutputAccess()
    }

    /// Resolves the output folder's bookmark: access started on the resolved URL, a stale bookmark refreshed, a
    /// moved folder followed. Nothing happens when it doesn't resolve (the folder is asked for at run time).
    private func restoreOutputAccess() {
        guard outputFolder != nil, let data = defaults.data(forKey: Key.folderBookmark),
              let found = FolderAccess.resolve(data) else { return }
        let grant = FolderAccess.Grant([found.url])
        outputAccess = grant
        // In the real sandbox only a security-scoped bookmark whose access started counts; otherwise the run asks.
        guard (found.isSecurityScoped || !Sandbox.isEnforced) && grant.givesAccess else { return }
        AccessStore.shared.addSessionRoot(found.url)
        if let refreshed = found.refreshed { defaults.set(refreshed, forKey: Key.folderBookmark) }
        let path = found.url.standardizedFileURL.path
        if path != outputFolder?.standardizedFileURL.path {
            // `didSet` stores the new path and a fresh bookmark (made while access is still on), then drops the
            // old access; it is started again on the resolved URL.
            outputFolder = URL(fileURLWithPath: path, isDirectory: true)
            outputAccess = FolderAccess.Grant([found.url])
        }
    }

    /// Nil only when the kind is "new folder" and no folder has been chosen yet.
    var outputMode: OutputMode? {
        switch modeKind {
        case .newFolder: return outputFolder.map { OutputMode.newFolder($0) }
        case .sameFolder: return .sameFolder(suffix: sameFolderSuffix)
        case .overwrite: return .overwrite
        }
    }
}
