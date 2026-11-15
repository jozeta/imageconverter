import Foundation

/// The privacy statement and the limits in force, in one place so the Privacy window, the README and the tests
/// agree with the code that enforces them.
public enum PrivacyStatement {
    public static let offline = "Works entirely offline. No network access, no telemetry, no uploads."
    /// Every Apple framework the sources import (besides the standard library and the app's own modules);
    /// `PrivacyStatementTests` fails when a source imports one that is not listed.
    public static let frameworkList = [
        "SwiftUI", "AppKit", "Foundation", "Observation", "Charts", "ImageIO", "Core Graphics", "Core Image",
        "Core Text", "Core Services", "Metal", "Accelerate", "Vision", "UniformTypeIdentifiers", "UserNotifications",
        "Security", "CryptoKit",
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
        ]
    }
}
