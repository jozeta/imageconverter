import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// Task 10 fix round 1: watermark assets by path, copies that ignore actions, tags on untouched originals, symlinked
/// subfolders, note sanitising, the preset metadata floor, per-folder preset libraries, the planner's name cap and
/// the rename pattern time limit.
final class ConditionReviewFixTests: XCTestCase {
    private var root: URL!
    private let always = Condition.width(.atLeast, 0)

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var out: URL { root.appendingPathComponent("out", isDirectory: true) }

    private func source(_ name: String, width: Int = 40, height: Int = 20) throws -> URL {
        let directory = root.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: .jpeg)
        return url
    }

    private func items(_ urls: [URL]) -> [InputItem] { urls.map { InputItem(source: $0, relativeDirectory: "") } }

    private func conditional(_ then: [ConditionalAction], steps: [PipelineStep] = []) -> Pipeline {
        Pipeline(steps: steps + [PipelineStep(operation: .condition(ConditionalStep(conditions: [always], then: then)))],
                 output: OutputSettings(format: .jpeg))
    }

    private func watermark(_ path: String, id: UUID) -> PipelineStep {
        PipelineStep(id: id, operation: .watermark(WatermarkOptions(content: .image(ImageWatermark(path: path)))))
    }

    // MARK: Watermark assets

    func testWatermarksWithTheSameStepIDButDifferentImagesAreBothLoaded() async throws {
        let logoA = root.appendingPathComponent("a.png")
        let logoB = root.appendingPathComponent("b.png")
        try TestImages.write(TestImages.make(width: 8, height: 8), to: logoA, type: .png)
        try TestImages.write(TestImages.make(width: 8, height: 8, color: CGColor(gray: 0.2, alpha: 1)), to: logoB, type: .png)
        // Preset B was saved from preset A, so their watermark steps share an id; B applies A in a condition.
        let sharedID = UUID()
        let directory = root.appendingPathComponent("presets", isDirectory: true)
        let presetA = Preset(name: "A", pipeline: Pipeline(steps: [watermark(logoA.path, id: sharedID)]))
        try PresetStore(directory: directory).save(presetA)
        let pipeline = conditional([.preset(PresetLink(presetA))], steps: [watermark(logoB.path, id: sharedID)])
        let report = await BatchRunner.run(items([try source("photo.jpg", width: 200, height: 100)]), pipeline: pipeline,
                                           mode: .newFolder(out), presets: .folder(directory))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.count, 1)

        let jobs = [pipeline.resolved(for: ItemFacts(width: 1, height: 1), presets: .folder(directory))]
        let paths = BatchRunner.assetPipeline(pipeline, resolved: jobs).steps.compactMap { step -> String? in
            guard case .watermark(let options) = step.operation, case .image(let image) = options.content else { return nil }
            return image.path
        }
        XCTAssertEqual(Set(paths), [logoA.path, logoB.path])
    }

    // MARK: Copies

    func testCopiedOriginalNotesWhatItIgnores() throws {
        let directory = root.appendingPathComponent("presets", isDirectory: true)
        let resize = PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(10))))
        let preset = Preset(name: "Small", pipeline: Pipeline(steps: [resize]))
        try PresetStore(directory: directory).save(preset)
        let resolved = conditional([.copyOriginal, .addKeywords(["k"]), .preset(PresetLink(preset))])
            .resolved(for: ItemFacts(width: 1, height: 1, format: .jpeg), presets: .folder(directory))
        XCTAssertEqual(resolved.disposition, .copyOriginal)
        XCTAssertEqual(resolved.notes, [ConditionalStep.ignoredForCopyPrefix + "added keywords, the preset's image steps"])
        // Without those actions a copy has no such note.
        XCTAssertEqual(conditional([.copyOriginal]).resolved(for: ItemFacts(width: 1, height: 1)).notes, [])
    }

    func testUntouchedOriginalIsNeverTagged() async throws {
        let photo = try source("a.jpg")
        let report = await BatchRunner.run(items([photo]), pipeline: conditional([.copyOriginal, .finderTags(["Done"])]),
                                           mode: .overwrite, trash: { _ in XCTFail("nothing may be trashed") })
        XCTAssertEqual(report.written, [photo])
        XCTAssertEqual(report.entries.first?.note, "\(ConditionalStep.copiedNote); \(FinderTags.untouchedNote)")
        let tags = try URL(fileURLWithPath: photo.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertEqual(tags, [])
    }

    // MARK: Subfolders through symbolic links

    func testSymlinkedSubfolderCannotLeaveTheOutputFolder() async throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("Link"), withDestinationURL: elsewhere)
        // A link that stays inside is fine.
        let inside = out.appendingPathComponent("Inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("Alias"), withDestinationURL: inside)
        let photo = try source("a.jpg")
        for (template, expected) in [("Link", "a.jpg"), ("Link/deeper", "a.jpg"), ("Alias", "Alias/a.jpg"), ("Plain/x", "Plain/x/a.jpg")] {
            let plan = await BatchRunner.plan(items([photo]), pipeline: conditional([.subfolder(template)]), mode: .newFolder(out))
            let destination = try XCTUnwrap(plan?.first?.destination)
            XCTAssertEqual(String(destination.path.dropFirst(out.path.count + 1)), expected, template)
        }
        let report = await BatchRunner.run(items([photo]), pipeline: conditional([.subfolder("Link")]), mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], "nothing written through the link")
    }

    // MARK: Notes

    func testNotesDropBidiAndFormatCharacters() {
        let context = RenameContext(name: "evil\u{202E}gpj.exe\u{200B}", ext: "jpg", format: "JPEG", folder: "f", date: nil,
                                    make: nil, model: "Cam\u{2066}era\u{0007}", lens: nil, iso: nil, width: 1, height: 1,
                                    counter: 1)
        XCTAssertEqual(RenameTemplate("Note \u{202B}{name} by {camera}").renderText(context), "Note evilgpj.exe by Camera")
    }

    // MARK: Presets

    func testAppliedPresetCannotWeakenTheMetadataFloor() throws {
        let directory = root.appendingPathComponent("presets", isDirectory: true)
        var keepAll = MetadataOptions(isEnabled: true, location: .keep)
        keepAll.artist = "Me"
        let preset = Preset(name: "Keeps everything", pipeline: Pipeline(metadata: keepAll))
        try PresetStore(directory: directory).save(preset)
        var pipeline = conditional([.preset(PresetLink(preset))])
        pipeline.metadata = MetadataOptions(isEnabled: true, location: .remove, removeCamera: true)
        let resolved = pipeline.resolved(for: ItemFacts(width: 1, height: 1), presets: .folder(directory)).pipeline.metadata
        XCTAssertEqual(resolved.location, .remove)
        XCTAssertTrue(resolved.removeCamera)
        XCTAssertEqual(resolved.artist, "Me", "what the preset sets still applies")
    }

    func testPresetLibrariesArePerFolder() throws {
        let first = root.appendingPathComponent("one", isDirectory: true)
        let second = root.appendingPathComponent("two", isDirectory: true)
        let preset = Preset(name: "Only in one", pipeline: Pipeline())
        try PresetStore(directory: first).save(preset)
        XCTAssertTrue(PresetLibrary.folder(first) === PresetLibrary.folder(first.appendingPathComponent(".")))
        XCTAssertNotNil(PresetLibrary.folder(first).preset(id: preset.id))
        XCTAssertNil(PresetLibrary.folder(second).preset(id: preset.id))
        XCTAssertNil(PresetLibrary.builtInsOnly.preset(id: preset.id))
        XCTAssertNotNil(PresetLibrary.builtInsOnly.preset(id: PresetStore.builtIns[0].id))
    }

    // MARK: Planner name cap

    func testPlannerGivesUpAfterTenThousandNames() async throws {
        let photo = try source("a.jpg")
        let item = InputItem(source: photo, relativeDirectory: "")
        let plans = OutputPlanner.plan([OutputTarget(item: item, format: .jpeg)], mode: .newFolder(out),
                                       fileExists: { _ in true })
        let plan = try XCTUnwrap(plans.first)
        XCTAssertTrue(plan.isRefused)
        XCTAssertEqual(plan.failureReason, OutputPlanner.noFreeNameReason)
        let (result, _) = BatchRunner.process(plan, job: ResolvedPipeline(pipeline: Pipeline()),
                                              assets: WatermarkAssets.load(for: Pipeline(), maxPixels: 1),
                                              maxPixels: 1_000_000, trash: { _ in XCTFail("nothing may be trashed") })
        guard case .failure(let error) = result else { return XCTFail("must fail") }
        XCTAssertTrue(error.reason.contains(OutputPlanner.noFreeNameReason), error.reason)
    }

    // MARK: Rename pattern time limit in a run

    func testSlowRenamePatternIsNotedAndChangesNothing() async throws {
        let photo = try source(String(repeating: "a", count: 40) + "b.jpg")
        var pipeline = Pipeline(output: OutputSettings(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, pattern: "{name}",
                                        replacements: [ReplacementRule(find: "(a+)+$", replace: "x", useRegex: true)])
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), [photo.lastPathComponent])
        XCTAssertEqual(report.entries.first?.note, BoundedRegex.timeoutNote)
    }
}
