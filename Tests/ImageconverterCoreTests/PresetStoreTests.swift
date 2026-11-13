import XCTest
@testable import ImageconverterCore

final class PresetStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PresetStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("presets-\(UUID().uuidString)", isDirectory: true)
        store = PresetStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func userPreset(_ name: String = "Mine") -> Preset {
        Preset(name: name, pipeline: Pipeline(
            steps: [PipelineStep(operation: .colorProfile(.displayP3))],
            output: OutputSettings(format: .png)))
    }

    private func writeRaw(_ text: String, name: String = UUID().uuidString + ".json") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    func testRoundTrip() throws {
        let preset = userPreset()
        try store.save(preset)
        let loaded = store.loadAll().presets.first { $0.id == preset.id }
        XCTAssertEqual(loaded, preset)
    }

    func testBuiltInsFirstWithExactPipelines() {
        let presets = store.loadAll().presets
        XCTAssertEqual(presets.prefix(3).map(\.name), ["Web export", "Instagram 4:5", "Archive TIFF"])
        XCTAssertTrue(presets.prefix(3).allSatisfy(\.isBuiltIn))
        let web = presets[0].pipeline
        XCTAssertEqual(web.steps.map(\.operation), [
            .resize(ResizeOptions(mode: .fitBox(width: 2048, height: 2048))), .colorProfile(.sRGB)])
        XCTAssertEqual(web.output, OutputSettings(format: .jpeg, quality: 0.82))
        XCTAssertEqual(web.metadata, MetadataOptions(isEnabled: true, removeLocation: true))
        let insta = presets[1].pipeline
        XCTAssertEqual(insta.steps.map(\.operation), [
            .resize(ResizeOptions(mode: .exactSize(width: 1080, height: 1350, fill: .fillAndCrop))),
            .colorProfile(.sRGB)])
        XCTAssertEqual(insta.output.quality, 0.85)
        let archive = presets[2].pipeline
        XCTAssertTrue(archive.steps.isEmpty)
        XCTAssertFalse(archive.metadata.isEnabled)
        XCTAssertEqual(archive.output.format, .tiff)
        XCTAssertEqual(archive.output.tiffCompression, .lzw)
    }

    func testUserPresetsSortedCaseInsensitively() throws {
        try store.save(userPreset("banana"))
        try store.save(userPreset("Apple"))
        try store.save(userPreset("cherry"))
        XCTAssertEqual(store.loadAll().presets.dropFirst(3).map(\.name), ["Apple", "banana", "cherry"])
    }

    func testBuiltInsAreReadOnly() {
        let builtIn = PresetStore.builtIns[0]
        XCTAssertThrowsError(try store.save(builtIn)) { XCTAssertEqual($0 as? PresetError, .builtInReadOnly) }
        XCTAssertThrowsError(try store.rename(id: builtIn.id, to: "X")) {
            XCTAssertEqual($0 as? PresetError, .builtInReadOnly)
        }
        XCTAssertThrowsError(try store.delete(id: builtIn.id)) {
            XCTAssertEqual($0 as? PresetError, .builtInReadOnly)
        }
    }

    func testNameRules() throws {
        let existing = PresetStore.builtIns
        XCTAssertThrowsError(try PresetStore.validatedName("  ", existing: existing, excluding: nil))
        XCTAssertThrowsError(try PresetStore.validatedName(String(repeating: "a", count: 81),
                                                           existing: existing, excluding: nil))
        XCTAssertEqual(try PresetStore.validatedName(String(repeating: "a", count: 80),
                                                     existing: existing, excluding: nil).count, 80)
        XCTAssertThrowsError(try PresetStore.validatedName("web export", existing: existing, excluding: nil)) {
            XCTAssertEqual($0 as? PresetError, .duplicateName)
        }
        XCTAssertEqual(try PresetStore.validatedName("  Hi\u{0007}\nthere \u{0000}", existing: existing,
                                                     excluding: nil), "Hithere")
        XCTAssertThrowsError(try PresetStore.validatedName("\u{0001}\u{0002}", existing: existing, excluding: nil))
        let mine = userPreset("Mine")
        XCTAssertEqual(try PresetStore.validatedName("mine", existing: [mine], excluding: mine.id), "mine")
    }

    func testSaveRejectsDuplicateName() throws {
        try store.save(userPreset("Mine"))
        XCTAssertThrowsError(try store.save(userPreset("MINE"))) {
            XCTAssertEqual($0 as? PresetError, .duplicateName)
        }
        XCTAssertThrowsError(try store.save(userPreset("web export")))
    }

    func testTamperedFilesAreSkippedAndOthersLoad() throws {
        let good = userPreset("Good")
        try store.save(good)
        let big = String(repeating: " ", count: 2 * 1_048_576)
        let bigName = UUID().uuidString + ".json"
        try writeRaw("{\"schemaVersion\":1,\"name\":\"x\"}" + big, name: bigName)
        let truncatedName = UUID().uuidString + ".json"
        try writeRaw("{\"schemaVersion\":1,\"id\":\"", name: truncatedName)
        let id = UUID()
        let badPipelineName = id.uuidString + ".json"
        try writeRaw("{\"schemaVersion\":1,\"id\":\"\(id.uuidString)\",\"name\":\"P\",\"pipeline\":5}",
                     name: badPipelineName)
        try writeRaw("{\"schemaVersion\":1}", name: "notes.json")
        let newerID = UUID()
        let newerName = newerID.uuidString + ".json"
        try writeRaw("{\"schemaVersion\":2,\"id\":\"\(newerID.uuidString)\",\"name\":\"N\",\"pipeline\":{}}",
                     name: newerName)

        let result = store.loadAll()
        XCTAssertTrue(result.presets.contains { $0.id == good.id })
        XCTAssertEqual(result.presets.count, 4)
        XCTAssertEqual(Set(result.skipped.map(\.file)), [bigName, truncatedName, badPipelineName, newerName])
        XCTAssertEqual(result.skipped.first { $0.file == bigName }?.reason, PresetError.tooLarge.reason)
        XCTAssertEqual(result.skipped.first { $0.file == newerName }?.reason,
                       PresetError.unsupportedVersion(2).reason)
        XCTAssertTrue(result.skipped.allSatisfy { !$0.reason.isEmpty })
    }

    func testUnknownStepKindIsDropped() throws {
        let id = UUID()
        try writeRaw("""
        {"schemaVersion":1,"id":"\(id.uuidString)","name":"Old","pipeline":{"steps":[
        {"id":"\(UUID().uuidString)","isEnabled":true,"operation":{"hologram":{}}},
        {"id":"\(UUID().uuidString)","isEnabled":true,"operation":{"colorProfile":{"_0":"sRGB"}}}]}}
        """, name: id.uuidString + ".json")
        let preset = try XCTUnwrap(store.loadAll().presets.first { $0.id == id })
        XCTAssertEqual(preset.pipeline.steps.count, 1)
        XCTAssertEqual(preset.pipeline.steps.first?.operation, .colorProfile(.sRGB))
    }

    func testDeleteRemovesFileAndMissingIsFine() throws {
        let preset = userPreset()
        try store.save(preset)
        let file = directory.appendingPathComponent("\(preset.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try store.delete(id: preset.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNoThrow(try store.delete(id: preset.id))
    }

    func testRenameKeepsId() throws {
        let preset = userPreset("Old")
        try store.save(preset)
        try store.rename(id: preset.id, to: "  New ")
        let loaded = try XCTUnwrap(store.loadAll().presets.first { $0.id == preset.id })
        XCTAssertEqual(loaded.name, "New")
        XCTAssertEqual(loaded.pipeline, preset.pipeline)
        XCTAssertThrowsError(try store.rename(id: preset.id, to: "web export"))
    }

    func testSavedFileHasSchemaVersionAndNoBuiltInFlag() throws {
        let preset = userPreset()
        try store.save(preset)
        let data = try Data(contentsOf: directory.appendingPathComponent("\(preset.id.uuidString).json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNil(object["isBuiltIn"])
    }

    func testSymlinkedFilesAreSkipped() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.txt")
        try Data(repeating: 32, count: 2 * 1_048_576).write(to: target)
        let linkA = UUID().uuidString + ".json"
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(linkA), withDestinationURL: target)
        let linkB = UUID().uuidString + ".json"
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(linkB).path,
                                                   withDestinationPath: "/dev/zero")
        let start = Date()
        let result = store.loadAll()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(Set(result.skipped.map(\.file)), [linkA, linkB])
        XCTAssertEqual(result.presets.count, 3)
    }

    func testFifoIsSkippedWithoutHanging() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".json"
        XCTAssertEqual(mkfifo(directory.appendingPathComponent(name).path, 0o600), 0)
        let result = store.loadAll()
        XCTAssertEqual(result.skipped.map(\.file), [name])
    }

    func testDuplicateNamesInFilesAreSkipped() throws {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        for (index, id) in ids.enumerated() {
            try writeRaw("{\"schemaVersion\":1,\"id\":\"\(id.uuidString)\",\"name\":\"Same\(index == 0 ? "" : " ")\",\"pipeline\":{}}",
                         name: id.uuidString + ".json")
        }
        let builtInClash = UUID()
        try writeRaw("{\"id\":\"\(builtInClash.uuidString)\",\"name\":\"WEB EXPORT\",\"pipeline\":{}}",
                     name: builtInClash.uuidString + ".json")
        let result = store.loadAll()
        XCTAssertEqual(result.presets.dropFirst(3).map(\.id), [ids[0]])
        XCTAssertEqual(Set(result.skipped.map(\.file)),
                       [ids[1].uuidString + ".json", builtInClash.uuidString + ".json"])
        XCTAssertTrue(result.skipped.allSatisfy { $0.reason == "A preset with this name already exists." })
    }

    func testNamesCompareWithUnicodeCaseFolding() {
        let existing = [Preset(name: "Straße", pipeline: Pipeline())]
        XCTAssertThrowsError(try PresetStore.validatedName("STRASSE", existing: existing, excluding: nil)) {
            XCTAssertEqual($0 as? PresetError, .duplicateName)
        }
    }

    func testIdAndFileNameMismatchIsSkipped() throws {
        let name = UUID().uuidString + ".json"
        try writeRaw("{\"id\":\"\(UUID().uuidString)\",\"name\":\"A\",\"pipeline\":{}}", name: name)
        XCTAssertEqual(store.loadAll().skipped.map(\.file), [name])
    }

    func testBuiltInIdInFileIsSkipped() throws {
        let builtIn = PresetStore.builtIns[0].id
        let name = builtIn.uuidString + ".json"
        try writeRaw("{\"id\":\"\(builtIn.uuidString)\",\"name\":\"Other\",\"pipeline\":{}}", name: name)
        let result = store.loadAll()
        XCTAssertEqual(result.skipped.map(\.file), [name])
        XCTAssertEqual(result.presets.count, 3)
    }

    func testRenameMissingThrows() {
        XCTAssertThrowsError(try store.rename(id: UUID(), to: "X")) {
            XCTAssertEqual($0 as? PresetError, .unreadable)
        }
    }

    func testDeleteRemovesDanglingSymlink() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let link = directory.appendingPathComponent("\(id.uuidString).json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/x")
        try store.delete(id: id)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testUnreadableFolderIsReported() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let result = store.loadAll()
        XCTAssertEqual(result.skipped.map(\.reason), ["The presets folder couldn't be read."])
    }

    func testInvalidJSONAndWrongTypesHaveDistinctReasons() throws {
        let badJSONID = UUID(), badTypeID = UUID()
        try writeRaw("{\"id\":", name: badJSONID.uuidString + ".json")
        try writeRaw("{\"id\":\"\(badTypeID.uuidString)\",\"name\":\"P\",\"pipeline\":5}", name: badTypeID.uuidString + ".json")
        let skipped = store.loadAll().skipped
        XCTAssertEqual(skipped.first { $0.file == badJSONID.uuidString + ".json" }?.reason, PresetError.invalidJSON.reason)
        XCTAssertEqual(skipped.first { $0.file == badTypeID.uuidString + ".json" }?.reason, PresetError.invalidStructure.reason)
    }
}
