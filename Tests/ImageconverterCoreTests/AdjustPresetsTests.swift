import XCTest
@testable import ImageconverterCore

final class AdjustPresetsTests: XCTestCase {
    private var directory: URL!
    private var store: AdjustPresetStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("adjustpresets-\(UUID().uuidString)", isDirectory: true)
        store = AdjustPresetStore.adjust(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFolderName() {
        XCTAssertEqual(AdjustPresetStore.adjustFolderName, "adjust-presets")
        XCTAssertEqual(AdjustPresetStore.defaultDirectory(folder: AdjustPresetStore.adjustFolderName)
            .lastPathComponent, "adjust-presets")
    }

    func testBuiltInNamesAndOrder() {
        XCTAssertEqual(AdjustPresets.builtIns.map(\.name), [
            "Vivid", "Vivid Warm", "Vivid Cool", "Dramatic", "Dramatic Warm", "Dramatic Cool", "Mono", "Silvertone",
            "Noir", "Fade", "Film", "Golden Hour", "Cool Breeze", "Matte", "Punch", "Soft Portrait"
        ])
        XCTAssertEqual(store.load().templates.prefix(16).map(\.name), AdjustPresets.builtIns.map(\.name))
    }

    func testBuiltInsAreDistinctInRangeAndRender() throws {
        let builtIns = AdjustPresets.builtIns
        XCTAssertTrue(builtIns.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(Set(builtIns.map(\.id)).count, builtIns.count)
        let image = TestImages.twoColor(width: 24, height: 24,
                                        left: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.7, alpha: 1),
                                        right: CGColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1))
        var seen: [AdjustOptions] = []
        for preset in builtIns {
            let options = preset.options
            XCTAssertFalse(options.isNeutral, preset.name)
            XCTAssertFalse(seen.contains(options), "\(preset.name) duplicates another look")
            seen.append(options)
            for field in AdjustOptions.Field.allCases {
                XCTAssertEqual(AdjustOptions.clamped(options[field], to: field), options[field], "\(preset.name) \(field)")
            }
            XCTAssertEqual(try Adjustments.apply(options, to: image).width, 24, preset.name)
        }
        // The black-and-white looks really are black and white.
        for name in ["Mono", "Noir"] {
            XCTAssertEqual(builtIns.first { $0.name == name }?.options.saturation, -100, name)
        }
    }

    func testBuiltInsAreReadOnly() {
        let builtIn = AdjustPresets.builtIns[0]
        XCTAssertThrowsError(try store.save(builtIn)) { XCTAssertEqual($0 as? PresetError, .builtInReadOnly) }
        XCTAssertThrowsError(try store.rename(id: builtIn.id, to: "Other")) {
            XCTAssertEqual($0 as? PresetError, .builtInReadOnly)
        }
        XCTAssertThrowsError(try store.delete(id: builtIn.id)) { XCTAssertEqual($0 as? PresetError, .builtInReadOnly) }
        // A built-in's name is taken.
        XCTAssertThrowsError(try store.save(AdjustPreset(name: "vivid", options: AdjustOptions(exposure: 1))))
    }

    func testRoundTripRenameDuplicateDelete() throws {
        let options = AdjustOptions(exposure: 12, warmth: -30, hue: 15, sharpness: -40, noiseReduction: 20)
        let saved = AdjustPreset(name: "Mine", options: options)
        try store.save(saved)
        var loaded = try XCTUnwrap(store.load().templates.first { $0.id == saved.id })
        XCTAssertEqual(loaded.options, options)
        XCTAssertFalse(loaded.isBuiltIn)
        let json = try XCTUnwrap(String(data: Data(contentsOf: directory
            .appendingPathComponent("\(saved.id.uuidString).json")), encoding: .utf8))
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"), json)
        XCTAssertTrue(json.contains("\"sharpness\" : -40"), json)

        try store.rename(id: saved.id, to: "Renamed")
        loaded = try XCTUnwrap(store.load().templates.first { $0.id == saved.id })
        XCTAssertEqual(loaded.name, "Renamed")

        let copy = AdjustPresets.duplicate(AdjustPresets.builtIns[3], existing: store.load().templates)
        XCTAssertEqual(copy.name, "Dramatic copy")
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertNotEqual(copy.id, AdjustPresets.builtIns[3].id)
        XCTAssertEqual(copy.options, AdjustPresets.builtIns[3].options)
        try store.save(copy)
        let second = AdjustPresets.duplicate(AdjustPresets.builtIns[3], existing: store.load().templates)
        XCTAssertEqual(second.name, "Dramatic copy 2")

        try store.delete(id: saved.id)
        XCTAssertNil(store.load().templates.first { $0.id == saved.id })
    }

    func testDuplicateNameStaysWithinTheLimit() {
        let long = AdjustPreset(name: String(repeating: "a", count: AdjustPresetStore.maxNameLength),
                                options: AdjustOptions(exposure: 1))
        let copy = AdjustPresets.duplicate(long, existing: [long])
        XCTAssertLessThanOrEqual(copy.name.count, AdjustPresetStore.maxNameLength)
        XCTAssertTrue(copy.name.hasSuffix(" copy"), copy.name)
    }

    /// The README's table of looks lists every built-in with exactly its values (the step summary wording).
    func testReadmeTableMatchesTheBuiltIns() throws {
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../README.md").standardizedFileURL
        let text = try String(contentsOf: readme, encoding: .utf8)
        for preset in AdjustPresets.builtIns {
            let row = "| \(preset.name) | \(preset.options.summary) |"
            XCTAssertTrue(text.contains(row), "README is missing: \(row)")
        }
    }
}
