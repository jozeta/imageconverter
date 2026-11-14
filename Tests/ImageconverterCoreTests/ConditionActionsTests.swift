import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// The actions added for Task 10: subfolder, Finder tags, preset, keywords, stop and note.
final class ConditionActionsTests: XCTestCase {
    private var root: URL!
    private let always = Condition.width(.atLeast, 0)

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var out: URL { root.appendingPathComponent("out", isDirectory: true) }

    private func source(_ name: String, in folder: URL? = nil, properties: [String: Any] = [:]) throws -> URL {
        let directory = folder ?? root.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .jpeg, properties: properties)
        return url
    }

    private func items(_ urls: [URL]) -> [InputItem] { urls.map { InputItem(source: $0, relativeDirectory: "") } }

    private func pipeline(_ then: [ConditionalAction], otherwise: [ConditionalAction] = [],
                          conditions: [Condition]? = nil) -> Pipeline {
        Pipeline(steps: [PipelineStep(operation: .condition(ConditionalStep(conditions: conditions ?? [always],
                                                                            then: then, otherwise: otherwise)))],
                 output: OutputSettings(format: .jpeg))
    }

    private func relative(_ url: URL?, to base: URL) -> String? {
        url.map { String($0.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1)) }
    }

    // MARK: Subfolder

    func testSubfolderInNewFolderModeWithTokens() async throws {
        let exif: [String: Any] = [kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifDateTimeOriginal as String: "2024:03:10 14:30:00"],
                                   kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "X-T5"]]
        let photo = try source("a.jpg", properties: exif)
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline([.subfolder("{date:yyyy}/{date:MM}/{camera}")]),
                                           mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(relative(report.written.first, to: out), "2024/03/X-T5/a.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.written[0].path))
    }

    func testSubfolderCollisionsArePerFolder() async throws {
        let first = try source("a.jpg")
        let second = try source("a.jpg", in: root.appendingPathComponent("other", isDirectory: true))
        let third = try source("b.jpg")
        // a.jpg and other/a.jpg both go into Portraits: the second becomes a_2. b.jpg goes elsewhere.
        let portraits = ConditionalStep(conditions: [Condition(.name(TextMatch(.equals, "a")))],
                                        then: [.subfolder("Portraits")], otherwise: [.subfolder("Rest")])
        let plan = await BatchRunner.plan(items([first, second, third]),
                                          pipeline: Pipeline(steps: [PipelineStep(operation: .condition(portraits))]),
                                          mode: .newFolder(out))
        XCTAssertEqual(plan?.map { relative($0.destination, to: out) }, ["Portraits/a.jpg", "Portraits/a_2.jpg", "Rest/b.jpg"])
        // An existing file in the subfolder is never replaced.
        let existing = out.appendingPathComponent("Rest", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: existing.appendingPathComponent("b.jpg"))
        let again = await BatchRunner.plan(items([third]), pipeline: Pipeline(steps: [PipelineStep(operation: .condition(portraits))]),
                                           mode: .newFolder(out))
        XCTAssertEqual(again?.map { relative($0.destination, to: out) }, ["Rest/b_2.jpg"])
    }

    func testSubfolderNeverEscapesTheRoot() async throws {
        let photo = try source("a.jpg")
        let attempts = ["../../etc", "/tmp/evil", "..", "./../x", "a/../../b", "{name}/../..", "~/Desktop", " / / "]
        for template in attempts {
            let plan = await BatchRunner.plan(items([photo]), pipeline: pipeline([.subfolder(template)]), mode: .newFolder(out))
            let destination = try XCTUnwrap(plan?.first?.destination)
            XCTAssertTrue(destination.standardizedFileURL.path.hasPrefix(out.standardizedFileURL.path + "/"),
                          "\(template) → \(destination.path)")
            XCTAssertFalse(destination.pathComponents.contains(".."), template)
        }
        // A token whose value holds a slash can't add a level.
        var context = RenameContext(name: "a/b", ext: "jpg", format: "JPEG", folder: "f", date: nil, make: nil,
                                    model: "../../x", lens: nil, iso: nil, width: 1, height: 1, counter: 1)
        XCTAssertEqual(SubfolderTemplate.folders("{camera}/{name}", context: context), ["x", "a-b"])
        context.model = nil
        XCTAssertEqual(SubfolderTemplate.folders("{camera}/Kept", context: context), ["Kept"], "an empty level is dropped")
        XCTAssertEqual(SubfolderTemplate.folders("1/2/3/4/5/6/7", context: context), ["1", "2", "3", "4", "5"], "at most 5 levels")
        // The planner drops unsafe names even when handed them directly.
        let target = OutputTarget(item: InputItem(source: photo, relativeDirectory: ""), format: .jpeg,
                                  subfolder: ["..", "ok", "a/b", ""])
        XCTAssertEqual(target.subfolder, ["ok"])
    }

    func testSubfolderInSameFolderModeAndIgnoredWhenOverwriting() async throws {
        let photo = try source("a.jpg")
        let same = await BatchRunner.run(items([photo]), pipeline: pipeline([.subfolder("Small")]),
                                         mode: .sameFolder(suffix: "_new"))
        XCTAssertEqual(relative(same.written.first, to: photo.deletingLastPathComponent()), "Small/a.jpg",
                       "no suffix: it isn't the original's own path")
        let overwrite = await BatchRunner.run(items([photo]), pipeline: pipeline([.subfolder("Small")]), mode: .overwrite,
                                              trash: { _ in })
        XCTAssertEqual(overwrite.written, [photo])
        XCTAssertEqual(overwrite.entries.first?.note, BatchRunner.subfolderIgnoredNote)
    }

    func testPreviewShowsTheSubfolder() async throws {
        let photo = try source("a.jpg")
        let outcome = await PreviewRenderer().render(item: InputItem(source: photo, relativeDirectory: ""), index: 0,
                                                     pipeline: pipeline([.subfolder("Portraits")]), mode: .newFolder(out))
        guard case .ready(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.outputName, "Portraits/a.jpg")
        XCTAssertEqual(relative(result.outputURL, to: out), "Portraits/a.jpg")
    }

    // MARK: Finder tags

    func testFinderTagsAreAddedToTheWrittenFile() async throws {
        let photo = try source("a.jpg")
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline([.finderTags(["Portraits", "portraits", "Work"])]),
                                           mode: .newFolder(out))
        let written = try XCTUnwrap(report.written.first)
        let tags = try URL(fileURLWithPath: written.path).resourceValues(forKeys: [.tagNamesKey]).tagNames
        XCTAssertEqual(tags, ["Portraits", "Work"])
        XCTAssertNil(report.entries.first?.note)
        XCTAssertEqual(FinderTags.normalized(Array(repeating: "x", count: 3) + (1...30).map { "t\($0)" }).count,
                       FinderTags.maxTags)
        // A copy of the original is tagged too.
        let copy = await BatchRunner.run(items([photo]), pipeline: pipeline([.copyOriginal, .finderTags(["Copied"])]),
                                         mode: .newFolder(root.appendingPathComponent("copies", isDirectory: true)))
        let copied = try XCTUnwrap(copy.written.first)
        XCTAssertEqual(try URL(fileURLWithPath: copied.path).resourceValues(forKeys: [.tagNamesKey]).tagNames, ["Copied"])
    }

    // MARK: Preset

    func testApplyPresetInsertsItsStepsAndSettings() throws {
        let directory = root.appendingPathComponent("presets", isDirectory: true)
        let store = PresetStore(directory: directory)
        let resize = PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(10))))
        var disabled = PipelineStep(operation: .colorProfile(.sRGB))
        disabled.isEnabled = false
        let inner = PipelineStep(operation: .condition(ConditionalStep(then: [.skip])))
        let saved = Preset(name: "Thumbs", pipeline: Pipeline(
            steps: [resize, disabled, inner], output: OutputSettings(format: .png),
            rename: RenameOptions(isEnabled: true, pattern: "{name}_thumb")))
        try store.save(saved)
        let library = PresetLibrary.folder(directory)
        let crop = PipelineStep(operation: .crop(CropOptions()))
        var base = pipeline([.preset(PresetLink(saved))])
        base.steps.append(crop)
        let resolved = base.resolved(for: ItemFacts(width: 100, height: 100), presets: library)
        XCTAssertEqual(resolved.pipeline.steps, [resize, crop], "enabled image steps only, never its conditions")
        XCTAssertEqual(resolved.pipeline.output.format, .png)
        XCTAssertEqual(resolved.pipeline.rename.pattern, "{name}_thumb")
        XCTAssertFalse(resolved.pipeline.metadata.isActive, "its Metadata step is off, so it doesn't apply")
        XCTAssertEqual(resolved.notes, [])

        // Saving again changes the folder, so the library reads it again; a deleted preset only leaves a note.
        try store.delete(id: saved.id)
        let missing = base.resolved(for: ItemFacts(width: 100, height: 100), presets: library)
        XCTAssertEqual(missing.pipeline.steps, [crop])
        XCTAssertEqual(missing.notes, [PresetLink(saved).missingNote])
        XCTAssertNotNil(library.preset(id: PresetStore.builtIns[0].id), "built-ins are always there")
    }

    func testMissingPresetIsNotedInTheReport() async throws {
        let photo = try source("a.jpg")
        let link = PresetLink(id: UUID(), name: "Gone")
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline([.preset(link)]), mode: .newFolder(out),
                                           presets: .folder(root.appendingPathComponent("no-presets", isDirectory: true)))
        XCTAssertEqual(report.written.count, 1)
        XCTAssertEqual(report.entries.first?.note, link.missingNote)
    }

    // MARK: Keywords

    func testAddKeywordsMergesAndKeepsTheFloor() {
        // No Metadata step: switched on with nothing removed, keywords added to the file's own.
        let plain = pipeline([.addKeywords(["Travel", " travel ", "Family"])]).resolved(for: ItemFacts(width: 1, height: 1))
        XCTAssertTrue(plain.pipeline.metadata.isActive)
        XCTAssertEqual(plain.pipeline.metadata.keywords, ["Travel", "Family"])
        XCTAssertEqual(plain.pipeline.metadata.keywordsMode, .add)
        XCTAssertEqual(plain.pipeline.metadata.location, .keep)
        XCTAssertFalse(plain.pipeline.metadata.hidesSourceData)

        // With a Metadata step that removes the location and sets keywords: both stay, the new ones join.
        var options = MetadataOptions(isEnabled: true, location: .remove)
        options.keywords = ["Mine"]
        var base = pipeline([.metadata(MetadataOptions(isEnabled: true, location: .keep)), .addKeywords(["Extra"])])
        base.metadata = options
        let merged = base.resolved(for: ItemFacts(width: 1, height: 1))
        XCTAssertEqual(merged.pipeline.metadata.location, .remove, "the floor stays")
        XCTAssertEqual(merged.pipeline.metadata.keywords, ["Extra"], "the override replaced the keywords, then added")
        base.steps = pipeline([.addKeywords(["Extra"])]).steps
        XCTAssertEqual(base.resolved(for: ItemFacts(width: 1, height: 1)).pipeline.metadata.keywords, ["Mine", "Extra"])
    }

    func testAddedKeywordsAreWritten() async throws {
        let photo = try source("a.jpg", properties: [kCGImagePropertyIPTCDictionary as String: [
            kCGImagePropertyIPTCKeywords as String: ["Old"]]])
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline([.addKeywords(["New"])]), mode: .newFolder(out))
        let written = try WrittenFile(url: try XCTUnwrap(report.written.first))
        let keywords = written.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCKeywords as String] as? [String]
        XCTAssertEqual(keywords, ["Old", "New"])
    }

    // MARK: Stop and note

    func testStopSkipsLaterConditionSteps() {
        let resize = PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(10))))
        let first = ConditionalStep(conditions: [always], then: [.stop, .output(OutputSettings(format: .png))])
        let second = ConditionalStep(conditions: [always], then: [.skip])
        let pipeline = Pipeline(steps: [PipelineStep(operation: .condition(first)), resize,
                                        PipelineStep(operation: .condition(second))])
        let resolved = pipeline.resolved(for: ItemFacts(width: 1, height: 1))
        XCTAssertEqual(resolved.disposition, .process, "the later skip isn't checked")
        XCTAssertEqual(resolved.pipeline.output.format, .png, "actions after Stop in the same branch still apply")
        XCTAssertEqual(resolved.pipeline.steps, [resize], "plain steps after it still run")
        // Stop in the branch not taken changes nothing.
        let other = ConditionalStep(conditions: [Condition.width(.atLeast, 5)], then: [.stop])
        let notTaken = Pipeline(steps: [PipelineStep(operation: .condition(other)), PipelineStep(operation: .condition(second))])
        XCTAssertEqual(notTaken.resolved(for: ItemFacts(width: 1, height: 1)).disposition, .skip)
    }

    func testNotesWithTokensInTheReport() async throws {
        let photo = try source("IMG_7.jpg")
        let skipped = try source("skip.jpg")
        let conditions = [Condition(.name(TextMatch(.startsWith, "IMG")))]
        let report = await BatchRunner.run(items([photo, skipped]), pipeline: pipeline(
            [.note("Check {name}: {width} px"), .note("second")], otherwise: [.skip, .note("Not a camera file")],
            conditions: conditions), mode: .newFolder(out))
        XCTAssertEqual(report.entries.first?.note, "Check IMG_7: 40 px; second")
        XCTAssertEqual(report.skipped.first?.reason, "\(ConditionalStep.skippedReason); Not a camera file")
        let copy = await BatchRunner.run(items([photo]), pipeline: pipeline([.copyOriginal, .note("kept")]),
                                         mode: .newFolder(root.appendingPathComponent("copies", isDirectory: true)))
        XCTAssertEqual(copy.entries.first?.note, "\(ConditionalStep.copiedNote); kept")
    }

    // MARK: Loading

    func testActionsRoundTripAndInvalidOnesAreDropped() throws {
        let actions: [ConditionalAction] = [.subfolder("{date:yyyy}"), .finderTags(["A"]), .preset(PresetLink(id: UUID(), name: "P")),
                                            .addKeywords(["k"]), .stop, .note("n")]
        let step = ConditionalStep(then: actions, otherwise: [.skip])
        XCTAssertEqual(try JSONDecoder().decode(ConditionalStep.self, from: JSONEncoder().encode(step)), step)
        let json = """
        {"conditions": [{"hasGPS": {"_0": true}}],
         "then": [{"subfolder": {"_0": " / "}}, {"finderTags": {"_0": ["  "]}}, {"addKeywords": {"_0": []}},
                  {"note": {"_0": ""}}, {"teleport": {}}, {"stop": {}}]}
        """
        XCTAssertEqual(try JSONDecoder().decode(ConditionalStep.self, from: Data(json.utf8)).then, [.stop])
        // A branch keeps at most 20 actions.
        let long = ConditionalStep(then: Array(repeating: .stop, count: 25))
        let decoded = try JSONDecoder().decode(ConditionalStep.self, from: JSONEncoder().encode(long))
        XCTAssertEqual(decoded.then.count, ConditionalStep.maxActions)
    }
}
