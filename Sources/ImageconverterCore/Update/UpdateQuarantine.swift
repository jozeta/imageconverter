import Foundation

/// Removes `com.apple.quarantine` from an installed update. Files a sandboxed process creates carry it ("created by
/// an AppSandbox, exec/open not allowed"), so the installer service (not sandboxed) unpacks and installs, and clears
/// any that remain on the bundle after it passed the Developer ID + notarized requirement.
public enum UpdateQuarantine {
    public static let attribute = "com.apple.quarantine"

    /// True when the bundle folder or anything inside it (links themselves, not their targets) is quarantined.
    public static func isQuarantined(_ bundle: URL) -> Bool {
        items(in: bundle).contains { getxattr($0.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    }

    /// Clears the attribute everywhere in the bundle; throws when some of it stays.
    public static func strip(_ bundle: URL) throws {
        for item in items(in: bundle) { _ = removexattr(item.path, attribute, XATTR_NOFOLLOW) }
        if isQuarantined(bundle) { throw UpdateError.installFailed("the installed app is still marked as quarantined.") }
    }

    private static func items(in bundle: URL) -> [URL] {
        var urls = [bundle]
        if let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { urls.append(url) }
        }
        return urls
    }
}
