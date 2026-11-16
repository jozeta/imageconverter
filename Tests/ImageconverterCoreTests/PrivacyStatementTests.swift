import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ImageconverterCore
import XCTest

final class PrivacyStatementTests: XCTestCase {
    /// Framework module names as they appear in `import`, mapped to the statement's display names.
    private static let moduleNames: [String: String] = [
        "SwiftUI": "SwiftUI", "AppKit": "AppKit", "Foundation": "Foundation", "Observation": "Observation",
        "Charts": "Charts", "ImageIO": "ImageIO", "CoreGraphics": "Core Graphics", "CoreImage": "Core Image",
        "CoreText": "Core Text", "CoreServices": "Core Services", "Metal": "Metal", "Accelerate": "Accelerate",
        "Vision": "Vision", "UniformTypeIdentifiers": "UniformTypeIdentifiers", "UserNotifications": "UserNotifications",
        "Security": "Security", "CryptoKit": "CryptoKit", "VideoToolbox": "VideoToolbox", "CoreVideo": "Core Video",
        "CoreMedia": "Core Media", "FoundationModels": "Foundation Models", "AppIntents": "App Intents",
    ]
    /// Not frameworks to list: the C library, GCD, and this package's own modules.
    private static let ignored: Set<String> = ["Darwin", "Dispatch", "ImageconverterCore", "ImageconverterCLIKit",
                                               "ImageconverterInstallerKit"]

    func testEveryImportedFrameworkIsListedInTheStatement() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(pattern: #"^(?:@preconcurrency\s+)?import\s+([A-Za-z0-9_]+)"#,
                                              options: [.anchorsMatchLines])
        var imported = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { imported.insert(String(text[range])) }
            }
        }
        XCTAssertGreaterThan(imported.count, 5, "Sources/ not found at \(root.path)")
        let unknown = imported.subtracting(Self.ignored).subtracting(Self.moduleNames.keys)
        XCTAssertEqual(unknown, [], "Sources import a framework the Privacy statement does not list")
        for module in imported.subtracting(Self.ignored) {
            if let name = Self.moduleNames[module] {
                XCTAssertTrue(PrivacyStatement.frameworkList.contains(name), module)
            }
        }
    }

    func testResultPrivacyDropsAfterMetadataRemoval() throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("leaky.jpg")
        try TestImages.write(TestImages.make(width: 120, height: 80), to: url, type: .jpeg, properties: [
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFArtist as String: "Jane"],
        ])
        let item = InputItem(source: url, relativeDirectory: "")
        let original = try XCTUnwrap(SizeEstimator.render(item: item, pipeline: Pipeline()).privacy)
        XCTAssertTrue(original.findings.contains { $0.kind == .location })
        let found = PrivacyScanner.scan(url)
        var pipeline = Pipeline()
        pipeline.metadata = found.suggestedMetadataOptions
        let cleaned = try XCTUnwrap(SizeEstimator.render(item: item, pipeline: pipeline).privacy)
        XCTAssertFalse(cleaned.findings.contains { $0.severity >= .medium }, "\(cleaned)")
    }
}
