import Foundation

/// The fixed rules for what an update download may be. Pure: no networking here.
public enum UpdatePolicy {
    /// Hosts a download URL may point at (also checked after redirects).
    public static let allowedHosts: Set<String> = ["github.com", "objects.githubusercontent.com",
                                                    "release-assets.githubusercontent.com"]
    public static let maxResponseBytes = 1_000_000
    public static let maxZipBytes = 200 * 1024 * 1024
    public static let maxChecksumBytes = 1024
    public static let maxNotesCharacters = 20_000

    /// The only host the release check talks to (the request URL itself is in the app's update client).
    public static let apiHost = "api.github.com"
    /// The released app's bundle identifier and the developer's team (must equal `release.sh`'s `BUNDLE_ID`).
    public static let bundleIdentifier = "io.github.jozeta.imageconverter"
    public static let teamIdentifier = "6W6TD6P8G3"
    /// The code requirement a downloaded app must meet: Developer ID signed by this team and notarized.
    public static let codeRequirement = "anchor apple generic and identifier \"\(bundleIdentifier)\" "
        + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and notarized"
    /// The bundle's folder name inside the release zip and next to the running app.
    public static let appBundleName = "imageconverter.app"

    /// The release check's URL (and any redirect of it): `https` on `apiHost`, no credentials, standard port.
    public static func allowedAPIURL(_ url: URL) -> Bool {
        isPlainHTTPS(url, hosts: [apiHost])
    }

    /// True for `https` on an allowed host, without credentials or a non-standard port.
    public static func allowedHost(_ url: URL) -> Bool {
        isPlainHTTPS(url, hosts: allowedHosts)
    }

    private static func isPlainHTTPS(_ url: URL, hosts: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              hosts.contains(host), url.user == nil, url.password == nil else { return false }
        if let port = url.port, port != 443 { return false }
        return true
    }

    public static func zipName(for version: AppVersion) -> String { "imageconverter-\(version).zip" }
    public static func checksumName(for version: AppVersion) -> String { "imageconverter-\(version).zip.sha256" }

    /// The lowercase hex digest from a `shasum -a 256` file (`<64 hex>  <name>`), or nil when the
    /// file is malformed, names another file, or holds more than one line.
    public static func expectedSHA256(from data: Data, fileName: String) -> String? {
        guard data.count <= maxChecksumBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).filter { !$0.isEmpty }
        guard lines.count == 1 else { return nil }
        let line = String(lines[0])
        guard let separator = line.range(of: "  ") ?? line.range(of: " *") else { return nil }
        let digest = String(line[..<separator.lowerBound])
        let name = String(line[separator.upperBound...])
        guard name == fileName, digest.utf8.count == 64,
              digest.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) })
        else { return nil }
        return digest.lowercased()
    }
}
