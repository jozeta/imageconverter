import Foundation
import Observation
import ImageconverterCore

/// User preferences for where converted files go, persisted in `UserDefaults`.
///
/// The output folder is stored as a plain path string for now. Security-scoped bookmarks arrive
/// with sandboxing in milestone 6.
@MainActor @Observable
final class AppSettings {
    private enum Key {
        static let modeKind = "outputModeKind"
        static let folder = "outputFolder"
        static let suffix = "sameFolderSuffix"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var modeKind: OutputModeKind {
        didSet { defaults.set(modeKind.rawValue, forKey: Key.modeKind) }
    }

    var outputFolder: URL? {
        didSet { defaults.set(outputFolder?.path, forKey: Key.folder) }
    }

    var sameFolderSuffix: String {
        didSet { defaults.set(sameFolderSuffix, forKey: Key.suffix) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        modeKind = defaults.string(forKey: Key.modeKind).flatMap(OutputModeKind.init(rawValue:)) ?? .newFolder
        outputFolder = defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        sameFolderSuffix = defaults.string(forKey: Key.suffix) ?? OutputPlanner.defaultSuffix
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
