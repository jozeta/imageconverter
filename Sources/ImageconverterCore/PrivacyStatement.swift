import Foundation

/// The privacy statement and the limits in force, in one place so the Privacy window, the README and the tests
/// agree with the code that enforces them.
public enum PrivacyStatement {
    public static let offline = "No network access except the optional update check and download from github.com. "
        + "No telemetry, no uploads."
    /// The one other network event, and it isn't the app's (Help ▸ Privacy, README, SECURITY.md).
    public static let enlargeModel = "The only other network activity: if you choose to download Apple's enlargement "
        + "model, macOS downloads it from Apple. It starts only from Download\u{2026} in the Resize step, after you agree; "
        + "batches, jobs, the command line, services, scripts and links never start it."
    /// Alt text (Help ▸ Privacy, README).
    public static let altText = "Alt text is written by Apple's on-device model (Apple Intelligence, macOS 27 and later) "
        + "on this Mac: the image and the text never leave it, and no server model is used. The app never asks macOS "
        + "to download the model; when it isn't ready, no alt text is written."
    /// What the update check sends and when (Help ▸ Privacy, README).
    public static let updates = "Updates: nothing goes online until you allow it. Check Now in About imageconverter, or "
        + "\u{201C}Check for updates when the app starts\u{201D}, asks GitHub's release API for the latest version. Like any web "
        + "request, it shows GitHub your IP address and standard HTTP headers (such as your preferred languages); the app adds "
        + "only \u{201C}imageconverter/<version>\u{201D} as the user agent, and nothing about you or your images. A download is "
        + "installed only when its checksum matches and the app is signed with the developer's Developer ID and notarized."
    /// Every Apple framework the sources import (besides the standard library and the app's own modules);
    /// `PrivacyStatementTests` fails when a source imports one that is not listed.
    public static let frameworkList = [
        "SwiftUI", "AppKit", "Foundation", "Observation", "Charts", "ImageIO", "Core Graphics", "Core Image",
        "Core Text", "Core Services", "Metal", "Accelerate", "Vision", "UniformTypeIdentifiers", "UserNotifications",
        "Security", "CryptoKit", "VideoToolbox", "Core Video", "Core Media", "Foundation Models", "App Intents",
    ]
    public static let frameworks = "Built only on Apple frameworks (" + frameworkList.joined(separator: ", ")
        + "); no third-party code."
    public static let tempFiles = "Temporary files written next to an output are deleted, not securely wiped: on "
        + "SSDs and APFS, overwriting a file does not reliably overwrite its old blocks."

    /// What the privacy scan looks for.
    public static let scanLooks = PrivacyFinding.Kind.allCases.map(\.title)

    public struct Limit: Equatable, Sendable {
        public let name: String
        public let value: String
    }

    /// Limits applied to untrusted input, with the values this build enforces.
    public static func limits(_ decode: DecodeLimits = .standard) -> [Limit] {
        let bytes = { (count: Int) in ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary) }
        let number = { (value: Int) in value.formatted(.number) }
        return [
            Limit(name: "Image pixels", value: "\(number(decode.maxPixels / 1_000_000)) megapixels"),
            Limit(name: "Image side", value: "\(number(decode.maxSide)) px"),
            Limit(name: "Decoded memory per image", value: bytes(decode.maxDecodedBytes)),
            Limit(name: "Image file size", value: bytes(decode.maxFileBytes)),
            Limit(name: "Frames read", value: "first frame only"),
            Limit(name: "SVG file size", value: bytes(SVGRasterizer.maxFileSize)),
            Limit(name: "SVG elements", value: number(SVGSanitizer.maxElements)),
            Limit(name: "SVG nesting depth", value: number(SVGSanitizer.maxDepth)),
            Limit(name: "SVG expanded instances", value: number(SVGSanitizer.maxInstances)),
            Limit(name: "Preset and template files", value: bytes(StoredFile.maxFileSize)),
            Limit(name: "imageconverter:// link length", value: "\(number(URLAction.maxURLLength)) characters"),
            Limit(name: "Files per link or script", value: number(ExternalRequests.maxFiles)),
            Limit(name: "Update check answer", value: bytes(UpdatePolicy.maxResponseBytes)),
            Limit(name: "Update download", value: bytes(UpdatePolicy.maxZipBytes)),
        ]
    }
}
