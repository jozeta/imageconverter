import Foundation

/// Facts about the app shared by the app and the command-line tool.
public enum AppInfo {
    /// Keep equal to the `VERSION` file; `AppInfoTests` fails when they differ.
    public static let version = "0.1.0"
}
