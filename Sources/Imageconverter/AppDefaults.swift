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

    /// A template folder (`folder` under Application Support), or a temporary one per suite in DEBUG
    /// screenshot launches.
    static func templatesDirectory(folder: String) -> URL {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-debugDefaultsSuite"), index + 1 < args.count {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("imageconverter-\(args[index + 1])/\(folder)", isDirectory: true)
        }
        #endif
        return WatermarkTemplateStore.defaultDirectory(folder: folder)
    }
}

extension AppDefaults {
    /// Saved jobs. DEBUG builds accept `-debugJobsDirectory <path>` (screenshots with prepared jobs); a debug
    /// suite otherwise gets its own temporary folder like the other templates.
    static let jobsDirectory: URL = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-debugJobsDirectory"), index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        #endif
        return templatesDirectory(folder: "jobs")
    }()

    /// Run history and the error log: the real folders, or temporary ones per DEBUG suite.
    static let historyDirectory: URL = debugFolder("history") ?? RunHistory.defaultDirectory
    static let logsDirectory: URL = debugFolder("logs") ?? ErrorLog.defaultDirectory

    private static func debugFolder(_ name: String) -> URL? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-debugDefaultsSuite"), index + 1 < args.count {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("imageconverter-\(args[index + 1])/\(name)", isDirectory: true)
        }
        #endif
        return nil
    }
}
