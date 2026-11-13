import Foundation
import ImageconverterCore

/// Where the app keeps its settings. DEBUG builds accept `-debugDefaultsSuite <name>`, so screenshot
/// and test launches use their own store and never change the user's real settings.
@MainActor
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-debugDefaultsSuite"), index + 1 < args.count,
           let suite = UserDefaults(suiteName: args[index + 1]) {
            return suite
        }
        #endif
        return .standard
    }()

    /// The preset folder: the real one, or a temporary folder per suite in DEBUG screenshot launches.
    static let presetsDirectory: URL = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-debugDefaultsSuite"), index + 1 < args.count {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("imageconverter-\(args[index + 1])/presets", isDirectory: true)
        }
        #endif
        return PresetStore.defaultDirectory
    }()
}
