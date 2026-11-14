import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class ConditionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func pipeline(_ conditional: ConditionalStep, output: OutputFormat = .jpeg) -> Pipeline {
        Pipeline(steps: [PipelineStep(operation: .condition(conditional))], output: OutputSettings(format: output))
    }

    private let resize = PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(100))))

    // MARK: Matching

    func testPortraitVsLandscape() {
        let portrait = ConditionalStep(conditions: [.orientation(.portrait)], then: [.step(resize)],
                                       otherwise: [.output(OutputSettings(format: .png))])
        let tall = pipeline(portrait).resolved(for: ItemFacts(width: 300, height: 400))
        XCTAssertEqual(tall.pipeline.steps.map(\.operation), [resize.operation])
        XCTAssertEqual(tall.pipeline.output.format, .jpeg)
        let wide = pipeline(portrait).resolved(for: ItemFacts(width: 400, height: 300))
        XCTAssertEqual(wide.pipeline.steps, [])
        XCTAssertEqual(wide.pipeline.output.format, .png)
        XCTAssertEqual(Orientation(width: 5, height: 5), .square)
        XCTAssertFalse(Condition.orientation(.portrait).matches(ItemFacts(width: 5, height: 5)))
    }

    func testAnyVsAll() {
        let conditions: [Condition] = [.width(.atLeast, 1000), .hasGPS(true)]
        let facts = ItemFacts(width: 1200, height: 10, hasGPS: false)
        XCTAssertFalse(ConditionalStep(match: .all, conditions: conditions).matches(facts))
        XCTAssertTrue(ConditionalStep(match: .any, conditions: conditions).matches(facts))
        XCTAssertFalse(ConditionalStep(match: .any, conditions: conditions).matches(ItemFacts(width: 10, height: 10)))
        XCTAssertTrue(ConditionalStep(match: .all, conditions: conditions)
            .matches(ItemFacts(width: 1000, height: 10, hasGPS: true)))
    }

    func testComparisonsAndOtherConditions() {
        let facts = ItemFacts(width: 2048, height: 1000, fileSize: 500, format: .jpeg, sourceType: "public.jpeg",
                              hasAlpha: true, make: "Apple", model: "iPhone 15 Pro")
        XCTAssertFalse(Condition.longestEdge(.greaterThan, 2048).matches(facts))
        XCTAssertTrue(Condition.longestEdge(.atLeast, 2048).matches(facts))
        XCTAssertTrue(Condition.height(.atMost, 1000).matches(facts))
        XCTAssertTrue(Condition.fileSize(.lessThan, bytes: 501).matches(facts))
        XCTAssertTrue(Condition.format(.format(.jpeg)).matches(facts))
        XCTAssertTrue(Condition.format(.type("public.image")).matches(facts), "conforming types match")
        XCTAssertFalse(Condition.format(.type("public.png")).matches(facts))
        XCTAssertTrue(Condition.hasTransparency(true).matches(facts))
        XCTAssertTrue(Condition.camera(contains: "iphone").matches(facts))
        XCTAssertTrue(Condition.camera(contains: " APPLE ").matches(facts))
        XCTAssertFalse(Condition.camera(contains: "Canon").matches(facts))
    }

    // MARK: Resolution

    func testResolutionOrderOverridesAndDispositions() {
        let first = ConditionalStep(conditions: [.width(.atLeast, 0)],
                                    then: [.output(OutputSettings(format: .png)), .copyOriginal])
        let second = ConditionalStep(conditions: [.width(.atLeast, 0)],
                                     then: [.output(OutputSettings(format: .tiff)), .step(resize),
                                            .rename(RenameOptions(pattern: "x"))])
        let crop = PipelineStep(operation: .crop(CropOptions()))
        var pipeline = Pipeline(steps: [crop, PipelineStep(operation: .condition(first)),
                                        PipelineStep(operation: .condition(second)), crop])
        let facts = ItemFacts(width: 10, height: 10, format: .heic)
        var resolved = pipeline.resolved(for: facts)
        XCTAssertEqual(resolved.disposition, .copyOriginal)
        XCTAssertEqual(resolved.pipeline.steps, [], "a copy runs no image steps")
        XCTAssertEqual(resolved.pipeline.output.format, .heic, "a copy keeps the source's format")
        XCTAssertTrue(resolved.pipeline.rename.isActive)
        XCTAssertEqual(resolved.statusNote, "Copied unchanged")

        // Skip wins over a copy, whatever the order.
        pipeline.steps.append(PipelineStep(operation: .condition(ConditionalStep(conditions: [.width(.atLeast, 0)],
                                                                                 then: [.skip]))))
        pipeline.steps.append(PipelineStep(operation: .condition(first)))
        resolved = pipeline.resolved(for: facts)
        XCTAssertEqual(resolved.disposition, .skip)

        // A disabled condition does nothing; no facts drops every condition.
        var disabled = PipelineStep(operation: .condition(ConditionalStep(conditions: [.width(.atLeast, 0)],
                                                                        then: [.skip])))
        disabled.isEnabled = false
        XCTAssertEqual(Pipeline(steps: [disabled]).resolved(for: facts), ResolvedPipeline(pipeline: Pipeline()))
        XCTAssertEqual(pipeline.resolved(for: nil).pipeline.steps.map(\.operation), [crop.operation, crop.operation])
    }

    func testMetadataOverrideIsSwitchedOn() {
        let strip = MetadataOptions(isEnabled: false, isIncluded: false, location: .remove)
        let resolved = pipeline(ConditionalStep(conditions: [.hasGPS(true)], then: [.metadata(strip)]))
            .resolved(for: ItemFacts(width: 1, height: 1, hasGPS: true))
        XCTAssertTrue(resolved.pipeline.metadata.isActive)
        XCTAssertEqual(resolved.pipeline.metadata.location, .remove)
    }

    func testNestedConditionBuiltInCodeIsIgnored() {
        let inner = PipelineStep(operation: .condition(ConditionalStep(conditions: [.width(.atLeast, 0)], then: [.skip])))
        let resolved = pipeline(ConditionalStep(conditions: [.width(.atLeast, 0)], then: [.step(inner)]))
            .resolved(for: ItemFacts(width: 1, height: 1))
        XCTAssertEqual(resolved, ResolvedPipeline(pipeline: Pipeline(output: OutputSettings(format: .jpeg))))
    }

    // MARK: Decoding

    func testRoundTrip() throws {
        let conditional = ConditionalStep(
            match: .any,
            conditions: [.longestEdge(.greaterThan, 2048), .fileSize(.atMost, bytes: 1000), .format(.format(.png)),
                         .format(.type("public.camera-raw-image")), .hasTransparency(false), .orientation(.square),
                         .hasGPS(true), .camera(contains: "Sony")],
            then: [.step(resize), .output(OutputSettings(format: .png)), .metadata(MetadataOptions(isEnabled: true)),
                   .rename(RenameOptions(pattern: "{name}_x")), .copyOriginal],
            otherwise: [.skip])
        let original = pipeline(conditional)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Pipeline.self, from: data), original)
    }

    private func decodeSteps(_ conditionJSON: String) throws -> [PipelineStep] {
        let json = """
        {"steps": [{"id": "\(UUID().uuidString)", "isEnabled": true, "operation": {"condition": {"_0": \(conditionJSON)}}},
                   {"id": "\(UUID().uuidString)", "isEnabled": true, "operation": {"colorProfile": {"_0": "sRGB"}}}]}
        """
        return try JSONDecoder().decode(Pipeline.self, from: Data(json.utf8)).steps
    }

    private func conditionJSON(_ condition: ConditionalStep) throws -> String {
        try XCTUnwrap(String(bytes: try JSONEncoder().encode(condition), encoding: .utf8))
    }

    func testNoNestingOnDecode() throws {
        // Encoding a nested condition is possible in code; loading it drops the inner one.
        let inner = PipelineStep(operation: .condition(ConditionalStep(then: [.skip])))
        let outer = ConditionalStep(then: [.step(inner), .step(resize)], otherwise: [.step(inner)])
        let steps = try decodeSteps(try conditionJSON(outer))
        XCTAssertEqual(steps.count, 2)
        guard case .condition(let decoded) = steps[0].operation else { return XCTFail("condition dropped") }
        XCTAssertEqual(decoded.then, [.step(resize)])
        XCTAssertEqual(decoded.otherwise, [])
    }

    func testInvalidConditionsAreDroppedOrRejected() throws {
        // A bad range or unknown condition is dropped; the valid one stays.
        var json = """
        {"match": "all", "conditions": [{"width": {"_0": "atLeast", "_1": -5}}, {"teleport": {}},
         {"camera": {"contains": "  "}}, {"format": {"_0": {"type": {"_0": "bad/type"}}}},
         {"hasGPS": {"_0": true}}], "then": [{"skip": {}}, {"unknown": {}}]}
        """
        var steps = try decodeSteps(json)
        guard case .condition(let decoded) = steps[0].operation else { return XCTFail("condition dropped") }
        XCTAssertEqual(decoded.conditions, [.hasGPS(true)])
        XCTAssertEqual(decoded.then, [.skip])

        // No valid condition left: the step goes, the rest of the pipeline stays.
        json = #"{"conditions": [{"width": {"_0": "atLeast", "_1": 99999999}}], "then": [{"skip": {}}]}"#
        steps = try decodeSteps(json)
        XCTAssertEqual(steps.map(\.operation.kind), [.colorProfile])

        // More than 10 conditions: rejected.
        let eleven = ConditionalStep(conditions: Array(repeating: .hasGPS(true), count: 11))
        steps = try decodeSteps(try conditionJSON(eleven))
        XCTAssertEqual(steps.map(\.operation.kind), [.colorProfile])
        let ten = ConditionalStep(conditions: Array(repeating: .hasGPS(true), count: 10))
        XCTAssertEqual(try decodeSteps(try conditionJSON(ten)).count, 2)
    }

    func testPresetWithConditionRoundTrips() throws {
        let store = PresetStore(directory: root.appendingPathComponent("presets"))
        let preset = Preset(name: "Big ones", pipeline: pipeline(ConditionalStep(then: [.step(resize)],
                                                                                 otherwise: [.copyOriginal])))
        try store.save(preset)
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.skipped.count, 0)
        XCTAssertEqual(loaded.presets.first { $0.id == preset.id }?.pipeline, preset.pipeline)
    }

    func testSummary() {
        let conditional = ConditionalStep(match: .any, conditions: [.longestEdge(.greaterThan, 2048), .hasGPS(true)],
                                          then: [.step(resize), .output(OutputSettings(format: .png))],
                                          otherwise: [.skip])
        XCTAssertEqual(ImageOperation.condition(conditional).summary,
                       "if longest edge > 2048 px or has location → resize, save as PNG · else → skip")
        XCTAssertEqual(ConditionalStep(then: []).summary, "if longest edge > 2048 px → nothing")
    }

    // MARK: Facts

    func testFactsFromFile() throws {
        let gps: [String: Any] = [
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 59.3,
                                                      kCGImagePropertyGPSLatitudeRef as String: "N"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Apple",
                                                       kCGImagePropertyTIFFModel as String: "iPhone 15 Pro"],
            kCGImagePropertyOrientation as String: 6
        ]
        let jpeg = root.appendingPathComponent("a.jpg")
        try TestImages.write(TestImages.make(width: 40, height: 20), to: jpeg, type: .jpeg, properties: gps)
        let facts = try XCTUnwrap(ItemFacts.read(jpeg))
        XCTAssertEqual(facts.width, 20, "upright size")
        XCTAssertEqual(facts.height, 40)
        XCTAssertEqual(facts.format, .jpeg)
        XCTAssertEqual(facts.sourceType, UTType.jpeg.identifier)
        XCTAssertTrue(facts.hasGPS)
        XCTAssertEqual(facts.make, "Apple")
        XCTAssertEqual(facts.model, "iPhone 15 Pro")
        XCTAssertFalse(facts.hasAlpha)
        XCTAssertEqual(facts.fileSize, BatchRunner.fileSize(jpeg))

        // PNG with an alpha channel: only real transparency counts.
        let opaque = root.appendingPathComponent("opaque.png")
        try TestImages.write(TestImages.make(width: 600, height: 600), to: opaque, type: .png)
        let clear = root.appendingPathComponent("clear.png")
        try TestImages.write(TestImages.make(width: 600, height: 600, alpha: 0.3), to: clear, type: .png)
        XCTAssertEqual(ImageLoader.header(of: opaque)?.properties[kCGImagePropertyHasAlpha as String] as? Bool, true,
                       "fixture must claim alpha")
        XCTAssertEqual(ItemFacts.read(opaque)?.hasAlpha, false)
        XCTAssertEqual(ItemFacts.read(clear)?.hasAlpha, true)
        XCTAssertEqual(ItemFacts.read(opaque, scanAlpha: false)?.hasAlpha, true, "without the scan the header decides")
        XCTAssertFalse(ItemFacts.read(opaque)?.hasGPS ?? true)

        let text = root.appendingPathComponent("not.png")
        try Data("hello".utf8).write(to: text)
        XCTAssertNil(ItemFacts.read(text))
    }

    // MARK: Fix round 1

    func testAlphaScanSkippedOverPixelLimit() throws {
        let opaque = root.appendingPathComponent("opaque.png")
        try TestImages.write(TestImages.make(width: 600, height: 600), to: opaque, type: .png)
        XCTAssertEqual(ItemFacts.read(opaque)?.hasAlpha, false, "scanned")
        // Over the limit nothing is decoded: the header's claim stands.
        XCTAssertEqual(ItemFacts.read(opaque, maxPixels: 600 * 600 - 1)?.hasAlpha, true)
        XCTAssertEqual(ItemFacts.read(opaque, maxPixels: 600 * 600)?.hasAlpha, false)
    }

    func testAlphaScanForTIFFAndHEIC() throws {
        var types: [(UTType, String)] = [(.tiff, "tif")]
        if OutputFormat.available().contains(.heic) { types.append((.heic, "heic")) }
        for (type, ext) in types {
            let opaque = root.appendingPathComponent("opaque.\(ext)")
            try TestImages.write(TestImages.make(width: 300, height: 300), to: opaque, type: type)
            let clear = root.appendingPathComponent("clear.\(ext)")
            try TestImages.write(TestImages.make(width: 300, height: 300, alpha: 0.3), to: clear, type: type)
            XCTAssertEqual(ItemFacts.read(clear)?.hasAlpha, true, ext)
            XCTAssertEqual(ItemFacts.read(opaque)?.hasAlpha, false, ext)
            // The scan only runs when the header claims alpha. The transparent fixture always does (so the scan
            // found it); HEIC writes an opaque image without an alpha channel, TIFF keeps one, which the scan rejects.
            func claims(_ url: URL) -> Bool? {
                ImageLoader.header(of: url)?.properties[kCGImagePropertyHasAlpha as String] as? Bool
            }
            XCTAssertEqual(claims(clear), true, ext)
            if type == .tiff { XCTAssertEqual(claims(opaque), true, "TIFF fixture must claim alpha") }
        }
    }

    func testDisabledOnlyConditionsAreStripped() throws {
        let url = root.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 10, height: 10), to: url, type: .png)
        var step = PipelineStep(operation: .condition(ConditionalStep(then: [.skip])))
        step.isEnabled = false
        let crop = PipelineStep(operation: .crop(CropOptions()))
        let resolved = Pipeline(steps: [step, crop]).resolved(forSource: url)
        XCTAssertEqual(resolved.pipeline.steps, [crop])
        XCTAssertEqual(resolved.disposition, .process)
    }

    func testCopyDropsImageSteps() {
        let resolved = pipeline(ConditionalStep(conditions: [.width(.atLeast, 0)], then: [.step(resize), .copyOriginal]))
            .resolved(for: ItemFacts(width: 500, height: 400))
        XCTAssertEqual(resolved.disposition, .copyOriginal)
        XCTAssertEqual(resolved.pipeline.steps, [])
    }

    func testPlannerReservesSkippedSources() {
        let folder = URL(fileURLWithPath: "/photos")
        let item = InputItem(source: folder.appendingPathComponent("a.jpg"), relativeDirectory: "")
        let skipped = folder.appendingPathComponent("b.jpg")
        let target = OutputTarget(item: item, format: .jpeg, baseName: "b")
        for mode in [OutputMode.sameFolder(suffix: ""), .newFolder(folder)] {
            let plans = OutputPlanner.plan([target], mode: mode, reservedSources: [skipped], fileExists: { _ in false })
            XCTAssertEqual(plans.first?.destination.lastPathComponent, "b_2.jpg", "\(mode)")
        }
        // Overwrite: a per-item format change must not land on a skipped file of that name.
        let png = OutputTarget(item: item, format: .png)
        let plans = OutputPlanner.plan([png], mode: .overwrite, reservedSources: [folder.appendingPathComponent("a.png")],
                                       fileExists: { _ in false })
        XCTAssertEqual(plans.first?.destination.lastPathComponent, "a_2.png")
    }
}
