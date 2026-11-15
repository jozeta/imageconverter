import Foundation

/// Facts about the app shared by the app and the command-line tool.
public enum AppInfo {
    /// Keep equal to the `VERSION` file; `AppInfoTests` fails when they differ.
    public static let compiledVersion = "1.2.0"

    /// The version shown to the user: the bundle's `CFBundleShortVersionString` when the app is
    /// packaged, else `compiledVersion` (a `swift run` build or the command-line tool).
    public static let version = version(from: Bundle.main.infoDictionary)

    /// The bundle's `CFBundleVersion`, or "dev" when there is none.
    public static let build = build(from: Bundle.main.infoDictionary)

    /// `info` is an Info.plist dictionary; blank or non-string values are ignored.
    public static func version(from info: [String: Any]?) -> String {
        nonEmpty(info?["CFBundleShortVersionString"]) ?? compiledVersion
    }

    public static func build(from info: [String: Any]?) -> String {
        nonEmpty(info?["CFBundleVersion"]) ?? "dev"
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
