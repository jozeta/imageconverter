import XCTest
@testable import ImageconverterCore

final class WatermarkTemplatesTests: XCTestCase {
    private var directory: URL!
    private var store: WatermarkTemplateStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wmtemplates-\(UUID().uuidString)", isDirectory: true)
        store = WatermarkTemplateStore.watermark(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFolderName() {
        XCTAssertEqual(WatermarkTemplateStore.watermarkFolderName, "watermark-templates")
        XCTAssertEqual(WatermarkTemplateStore.defaultDirectory(folder: WatermarkTemplateStore.watermarkFolderName)
            .lastPathComponent, "watermark-templates")
    }

    func testRoundTripKeepsEveryField() throws {
        let options = WatermarkOptions(
            content: .image(ImageWatermark(path: "/Users/me/logo.svg", shadow: WatermarkShadow(blur: 4, offset: 2))),
            anchor: .topLeft, sizePercent: 12, opacity: 0.4, marginPercent: 2, rotation: -15,
            layout: .tiled(spacing: 80, stagger: false))
        let saved = WatermarkTemplate(name: "Logo", options: options)
        try store.save(saved)
        let loaded = try XCTUnwrap(store.load().templates.first { $0.id == saved.id })
        XCTAssertEqual(loaded.options, options)
        XCTAssertFalse(loaded.isBuiltIn)
        let file = directory.appendingPathComponent("\(saved.id.uuidString).json")
        let json = try XCTUnwrap(String(data: Data(contentsOf: file), encoding: .utf8))
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"), json)
        XCTAssertTrue(json.contains("logo.svg"), json)
    }

    func testBuiltIns() {
        let templates = store.load().templates
        XCTAssertEqual(templates.prefix(3).map(\.name), ["© corner (bottom right, 4 %)",
                                                         "Tiled diagonal (30°, 15 % opacity)",
                                                         "Filename + date (bottom left)"])
        let builtIns = WatermarkTemplates.builtIns
        XCTAssertTrue(builtIns.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(builtIns[0].options.anchor, .bottomRight)
        XCTAssertEqual(builtIns[0].options.sizePercent, 4)
        XCTAssertEqual(builtIns[1].options.rotation, -30)
        XCTAssertEqual(builtIns[1].options.opacity, 0.15)
        XCTAssertEqual(builtIns[1].options.layout, .tiled(spacing: 100, stagger: true))
        XCTAssertEqual(builtIns[2].options.anchor, .bottomLeft)
        guard case .text(let text) = builtIns[2].options.content else { return XCTFail("text expected") }
        XCTAssertTrue(text.text.contains("{filename}") && text.text.contains("{date}"))
        XCTAssertThrowsError(try store.save(builtIns[0])) { XCTAssertEqual($0 as? PresetError, .builtInReadOnly) }
        XCTAssertThrowsError(try store.delete(id: builtIns[1].id)) {
            XCTAssertEqual($0 as? PresetError, .builtInReadOnly)
        }
    }

    func testHardenedLikeOtherStores() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        let big = UUID()
        try Data(repeating: 0x20, count: 1_048_577).write(to: directory.appendingPathComponent("\(big.uuidString).json"))
        let result = store.load()
        XCTAssertEqual(result.templates.count, 3)
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertThrowsError(try store.save(WatermarkTemplate(name: "© corner (bottom right, 4 %)",
                                                              options: WatermarkOptions()))) {
            XCTAssertEqual($0 as? PresetError, .duplicateName)
        }
    }
}
