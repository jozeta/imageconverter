import XCTest
@testable import ImageconverterCore

final class PresetPinTests: XCTestCase {
    private var directory: URL!
    private var store: PresetStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("presetpins-\(UUID().uuidString)", isDirectory: true)
        store = PresetStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func json(_ preset: Preset) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(preset.id.uuidString).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func loaded(_ id: UUID) throws -> Preset {
        try XCTUnwrap(store.loadAll().presets.first { $0.id == id })
    }

    func testUnpinnedFilesDontStoreTheFlag() throws {
        let preset = Preset(name: "Mine", pipeline: Pipeline())
        try store.save(preset)
        XCTAssertNil(try json(preset)["pinnedForServices"])
        XCTAssertFalse(try loaded(preset.id).pinnedForServices)
    }

    func testPinRoundTripKeepsPipelineAndName() throws {
        let preset = Preset(name: "Mine", pipeline: Pipeline(output: OutputSettings(format: .png)))
        try store.save(preset)
        try store.setPinnedForServices(id: preset.id, true)
        XCTAssertEqual(try json(preset)["pinnedForServices"] as? Bool, true)
        let pinned = try loaded(preset.id)
        XCTAssertTrue(pinned.pinnedForServices)
        XCTAssertEqual(pinned.pipeline, preset.pipeline)
        XCTAssertEqual(pinned.name, "Mine")
        try store.setPinnedForServices(id: preset.id, false)
        XCTAssertFalse(try loaded(preset.id).pinnedForServices)
    }

    func testAtMostFivePinned() throws {
        var ids: [UUID] = []
        for index in 0..<6 {
            let preset = Preset(name: "P\(index)", pipeline: Pipeline())
            try store.save(preset)
            ids.append(preset.id)
        }
        for id in ids.prefix(5) { try store.setPinnedForServices(id: id, true) }
        XCTAssertThrowsError(try store.setPinnedForServices(id: ids[5], true)) {
            XCTAssertEqual($0 as? PresetError, .tooManyPinned)
        }
        var sixth = try loaded(ids[5])
        sixth.pinnedForServices = true
        XCTAssertThrowsError(try store.save(sixth)) { XCTAssertEqual($0 as? PresetError, .tooManyPinned) }
        // Saving one that is already pinned is fine.
        try store.save(try loaded(ids[0]))
        try store.setPinnedForServices(id: ids[0], false)
        try store.setPinnedForServices(id: ids[5], true)
        XCTAssertEqual(ServicePins.pinned(store.loadAll().presets).count, 5)
    }

    func testBuiltInsCantBePinned() {
        XCTAssertThrowsError(try store.setPinnedForServices(id: PresetStore.builtIns[0].id, true)) {
            XCTAssertEqual($0 as? PresetError, .builtInReadOnly)
        }
    }
}
