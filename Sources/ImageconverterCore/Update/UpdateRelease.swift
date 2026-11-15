import Foundation

/// Why an update check or install was refused. `message` is shown to the user.
public enum UpdateError: Error, Equatable, Sendable {
    case responseTooLarge
    case invalidResponse
    case noSuitableRelease
    case badChecksumFile
    case checksumMismatch
    case downloadTooLarge
    case disallowedURL
    case installRefused(String)

    public var message: String {
        switch self {
        case .responseTooLarge: "The update server's answer was too large."
        case .invalidResponse: "The update server's answer could not be read."
        case .noSuitableRelease: "The latest release is not a valid update."
        case .badChecksumFile: "The update's checksum file is not valid."
        case .checksumMismatch: "The downloaded update does not match its checksum."
        case .downloadTooLarge: "The update download is too large."
        case .disallowedURL: "The update points to an address that is not allowed."
        case .installRefused(let reason): reason
        }
    }
}

/// A release that is newer than the running app and passed every rule.
public struct UpdateRelease: Equatable, Sendable {
    public let version: AppVersion
    public let notes: String
    public let zipURL: URL
    public let shaURL: URL

    /// Parses a GitHub "latest release" response (untrusted). Returns nil when `current` is
    /// already that version or newer; throws when the answer is broken or breaks a rule.
    public static func parse(_ data: Data, current: AppVersion) throws -> UpdateRelease? {
        guard data.count <= UpdatePolicy.maxResponseBytes else { throw UpdateError.responseTooLarge }
        let payload: ReleasePayload
        do { payload = try JSONDecoder().decode(ReleasePayload.self, from: data) } catch { throw UpdateError.invalidResponse }
        guard payload.draft != true, payload.prerelease != true,
              payload.tag.hasPrefix("v"), let version = AppVersion(String(payload.tag.dropFirst()))
        else { throw UpdateError.noSuitableRelease }
        guard version > current else { return nil }

        let assets = payload.assets ?? []
        guard let zip = assets.first(where: { $0.name == UpdatePolicy.zipName(for: version) }),
              let sha = assets.first(where: { $0.name == UpdatePolicy.checksumName(for: version) })
        else { throw UpdateError.noSuitableRelease }
        guard let zipSize = zip.size, let shaSize = sha.size else { throw UpdateError.noSuitableRelease }
        guard (1...UpdatePolicy.maxZipBytes).contains(zipSize), (1...UpdatePolicy.maxChecksumBytes).contains(shaSize)
        else { throw UpdateError.downloadTooLarge }
        guard let zipURL = URL(string: zip.url), let shaURL = URL(string: sha.url),
              UpdatePolicy.allowedHost(zipURL), UpdatePolicy.allowedHost(shaURL)
        else { throw UpdateError.disallowedURL }

        return UpdateRelease(version: version, notes: String((payload.body ?? "").prefix(UpdatePolicy.maxNotesCharacters)),
                             zipURL: zipURL, shaURL: shaURL)
    }
}

private struct ReleasePayload: Decodable {
    let tag: String
    let draft: Bool?
    let prerelease: Bool?
    let body: String?
    let assets: [ReleaseAsset]?
    enum CodingKeys: String, CodingKey { case tag = "tag_name", draft, prerelease, body, assets }
}

private struct ReleaseAsset: Decodable {
    let name: String
    let url: String
    let size: Int?
    enum CodingKeys: String, CodingKey { case name, url = "browser_download_url", size }
}
