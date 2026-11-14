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
        XCTAssertNil(try json(preset)["serviceSlot"])
        XCTAssertFalse(try loaded(preset.id).pinnedForServices)
    }

    func testPinRoundTripKeepsPipelineAndName() throws {
        let preset = Preset(name: "Mine", pipeline: Pipeline(output: OutputSettings(format: .png)))
        try store.save(preset)
        try store.setPinnedForServices(id: preset.id, true)
        XCTAssertEqual(try json(preset)["serviceSlot"] as? Int, 1)
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
        sixth.serviceSlot = 2
        XCTAssertThrowsError(try store.save(sixth)) { XCTAssertEqual($0 as? PresetError, .serviceSlotTaken) }
        // Saving one that is already pinned is fine.
        try store.save(try loaded(ids[0]))
        try store.setPinnedForServices(id: ids[0], false)
        try store.setPinnedForServices(id: ids[5], true)
        XCTAssertEqual(ServicePins.pinned(store.loadAll().presets).count, 5)
    }

    func testSlotsStayPutAcrossRenamesAndUnpinning() throws {
        let names = ["c", "a", "b"]
        var ids: [UUID] = []
        for name in names {
            let preset = Preset(name: name, pipeline: Pipeline())
            try store.save(preset)
            try store.setPinnedForServices(id: preset.id, true)
            ids.append(preset.id)
        }
        XCTAssertEqual(try ids.map { try loaded($0).serviceSlot }, [1, 2, 3])
        try store.rename(id: ids[0], to: "zzz")
        XCTAssertEqual(try loaded(ids[0]).serviceSlot, 1)
        // Unpinning slot 2 leaves 1 and 3 where they are; the next pin takes 2.
        try store.setPinnedForServices(id: ids[1], false)
        XCTAssertEqual(try loaded(ids[2]).serviceSlot, 3)
        XCTAssertNil(ServicePins.preset(forSlot: 2, in: store.loadAll().presets))
        let next = Preset(name: "new", pipeline: Pipeline())
        try store.save(next)
        try store.setPinnedForServices(id: next.id, true)
        XCTAssertEqual(try loaded(next.id).serviceSlot, 2)
    }

    func testOutOfRangeSlotsLoadAsUnpinned() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "{\"id\":\"\(id.uuidString)\",\"name\":\"X\",\"pipeline\":{},\"serviceSlot\":9}"
        try Data(text.utf8).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        XCTAssertNil(try loaded(id).serviceSlot)
    }

    func testBuiltInsCantBePinned() {
        XCTAssertThrowsError(try store.setPinnedForServices(id: PresetStore.builtIns[0].id, true)) {
            XCTAssertEqual($0 as? PresetError, .builtInReadOnly)
        }
    }
}
