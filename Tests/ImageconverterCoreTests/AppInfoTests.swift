import XCTest
@testable import ImageconverterCore

final class AppInfoTests: XCTestCase {
    func testVersionMatchesVersionFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        XCTAssertEqual(AppInfo.compiledVersion, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testVersionAndBuildFallBackWithoutBundleValues() {
        XCTAssertEqual(AppInfo.version(from: nil), AppInfo.compiledVersion)
        XCTAssertEqual(AppInfo.version(from: ["CFBundleShortVersionString": "  ", "CFBundleVersion": 3]), AppInfo.compiledVersion)
        XCTAssertEqual(AppInfo.build(from: [:]), "dev")
        XCTAssertEqual(AppInfo.build(from: ["CFBundleVersion": 7]), "dev")
    }

    func testBundleValuesWin() {
        let info: [String: Any] = ["CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "42"]
        XCTAssertEqual(AppInfo.version(from: info), "2.3.4")
        XCTAssertEqual(AppInfo.build(from: info), "42")
    }

    func testPipelineFileAcceptsPipelineAndPresetAndRejectsOthers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pipeline = Pipeline(output: OutputSettings(format: .png))
        let plain = dir.appendingPathComponent("p.json")
        try JSONEncoder().encode(pipeline).write(to: plain)
        XCTAssertEqual(try PipelineFile.load(plain).output.format, .png)
        let preset = dir.appendingPathComponent("preset.json")
        try JSONEncoder().encode(Preset(name: "X", pipeline: pipeline)).write(to: preset)
        XCTAssertEqual(try PipelineFile.load(preset).output.format, .png)
        let junk = dir.appendingPathComponent("junk.json")
        try Data("{\"hello\":1}".utf8).write(to: junk)
        XCTAssertThrowsError(try PipelineFile.load(junk))
        let bad = dir.appendingPathComponent("bad.json")
        try Data("not json".utf8).write(to: bad)
        XCTAssertThrowsError(try PipelineFile.load(bad))
        XCTAssertThrowsError(try PipelineFile.load(dir.appendingPathComponent("missing.json")))
    }
}
