import XCTest
@testable import ImageconverterCore

/// Extra outputs with their own Save to (round 3): the model, old files, planning, collisions and folder access.
final class OutputDestinationTests: XCTestCase {
    private var root: URL!
    private var out: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
        out = root.appendingPathComponent("out", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, in folder: URL? = nil) throws -> URL {
        let directory = folder ?? root!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try TestImages.write(TestImages.noise(width: 300, height: 200), to: url, type: .jpeg)
        return url
    }

    private func items(_ urls: [URL]) -> [InputItem] { urls.map { InputItem(source: $0, relativeDirectory: "") } }

    private func relative(_ url: URL) -> String { url.path.replacingOccurrences(of: root.path + "/", with: "") }

    // MARK: Model and old files

    func testOldVariantJSONLoadsBesideTheMainOutputAndEncodesUnchanged() throws {
        let json = #"{"extraOutputs":[{"name":"Thumb","nameSuffix":"_t","settings":{"format":"png"},"subfolder":"s"}]}"#
        let pipeline = try JSONDecoder().decode(Pipeline.self, from: Data(json.utf8))
        XCTAssertEqual(pipeline.extraOutputs.count, 1)
        XCTAssertNil(pipeline.extraOutputs[0].destination)
        XCTAssertEqual(pipeline.extraOutputs[0].subfolder, "s")
        let encoded = String(bytes: try JSONEncoder().encode(pipeline.extraOutputs[0]), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("destination"), encoded)
    }

    func testEveryDestinationRoundTrips() throws {
        let destinations: [OutputDestination] = [
            .folder(VariantFolder(path: "/Users/someone/Web", bookmark: Data([1, 2, 3]))),
            .folder(VariantFolder(path: "/Volumes/Disk/x")),
            .sameFolder,
            .subfolder("thumbs/{date:yyyy}"),
        ]
        var pipeline = Pipeline()
        pipeline.extraOutputs = destinations.enumerated().map {
            OutputVariant(name: "O\($0.offset)", nameSuffix: "_\($0.offset)", destination: $0.element)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(pipeline)
        let decoded = try JSONDecoder().decode(Pipeline.self, from: data)
        XCTAssertEqual(decoded.extraOutputs.map(\.destination), destinations)
        XCTAssertEqual(try encoder.encode(decoded), data)
        XCTAssertTrue((String(bytes: data, encoding: .utf8) ?? "").contains(#""kind":"sameFolder""#))
    }

    func testAnUnreadableDestinationDropsTheOutputWithANote() throws {
        let json = """
        {"extraOutputs":[
          {"name":"Future","nameSuffix":"_f","destination":{"kind":"cloud"}},
          {"name":"Relative","nameSuffix":"_r","destination":{"kind":"folder","path":"some/where"}},
          {"name":"Fine","nameSuffix":"_ok","destination":{"kind":"folder","path":"/tmp/a/../b","bookmark":5}}
        ]}
        """
        let pipeline = try JSONDecoder().decode(Pipeline.self, from: Data(json.utf8))
        XCTAssertEqual(pipeline.extraOutputs.map(\.name), ["Fine"])
        // The path is standardised and an unreadable bookmark dropped.
        XCTAssertEqual(pipeline.extraOutputs[0].destination, .folder(VariantFolder(path: "/tmp/b")))
        XCTAssertEqual(pipeline.loadNotes.notes.count, 2, "\(pipeline.loadNotes.notes)")
        XCTAssertTrue(pipeline.loadNotes.notes.contains("Extra output “Future” couldn't be read and was left out"))
    }

    func testADestinationWithoutItsFolderCantRun() {
        let noFolder = OutputVariant(name: "A", nameSuffix: "_a", destination: .folder(VariantFolder()))
        let noName = OutputVariant(name: "B", nameSuffix: "_b", destination: .subfolder(" / "))
        let fine = OutputVariant(name: "C", nameSuffix: "_c", destination: .sameFolder)
        let problems = OutputVariant.problems(in: [noFolder, noName, fine])
        XCTAssertEqual(problems[noFolder.id], OutputVariant.noFolderProblem)
        XCTAssertEqual(problems[noName.id], OutputVariant.noSubfolderProblem)
        XCTAssertNil(problems[fine.id])
        XCTAssertNotNil(OutputVariant.runBlocker(in: [noFolder]))
    }

    func testSuffixesMustDifferEvenInDifferentFolders() {
        let one = OutputVariant(name: "A", nameSuffix: "_x", destination: .folder(VariantFolder(path: "/a")))
        let two = OutputVariant(name: "B", nameSuffix: "_X", destination: .folder(VariantFolder(path: "/b")))
        XCTAssertEqual(OutputVariant.problems(in: [one, two])[two.id], OutputVariant.duplicateSuffixProblem)
    }

    func testAddedOutputCopiesTheMainSettingsWithAFreeNameAndSuffix() {
        let main = OutputSettings(format: .png, quality: 0.42, progressive: true)
        let first = OutputVariant.added(after: [], main: main)
        XCTAssertEqual(first.name, "Output 2")
        XCTAssertEqual(first.nameSuffix, "_out2")
        XCTAssertEqual(first.settings, main)
        XCTAssertNil(first.resize)
        XCTAssertNil(first.destination)
        let second = OutputVariant.added(after: [first], main: main)
        XCTAssertEqual(second.name, "Output 3")
        XCTAssertEqual(second.nameSuffix, "_out3")
        // A name already used moves the number on.
        let renamed = OutputVariant(name: "Output 3", nameSuffix: "_z")
        XCTAssertEqual(OutputVariant.added(after: [first, renamed], main: main).name, "Output 4")
        XCTAssertTrue(OutputVariant.problems(in: [first, second]).isEmpty)
    }

    func testExtraOutputDefaultNamesStartAtTwo() throws {
        // The main output is the "Output 1" card; extra outputs follow the card numbering.
        XCTAssertEqual(OutputVariant.mainOutputName, "Output 1")
        let main = OutputSettings(format: .jpeg)
        let first = OutputVariant.added(after: [], main: main)
        let second = OutputVariant.added(after: [first], main: main)
        XCTAssertEqual([first.name, second.name], ["Output 2", "Output 3"])
        XCTAssertEqual(OutputVariant.defaultName(4), "Output 4")
        // A name saved before (also "Output 1") loads unchanged.
        let saved = OutputVariant(name: "Output 1", nameSuffix: "_old")
        let loaded = try JSONDecoder().decode(OutputVariant.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(loaded.name, "Output 1")
        XCTAssertEqual(OutputVariant.added(after: [loaded], main: main).name, "Output 3")
    }

    // MARK: Planning

    func testEachDestinationWritesWhereItSays() async throws {
        let photo = try source("a.jpg", in: root.appendingPathComponent("src"))
        let web = root.appendingPathComponent("web", isDirectory: true)
        let variants = [
            OutputVariant(name: "Beside", nameSuffix: "_beside"),
            OutputVariant(name: "Web", nameSuffix: "_web", subfolder: "big",
                          destination: .folder(VariantFolder(path: web.path))),
            OutputVariant(name: "Here", nameSuffix: "_here", destination: .sameFolder),
            OutputVariant(name: "Sub", nameSuffix: "_sub", destination: .subfolder("thumbs/{ext}")),
        ]
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), extraOutputs: variants)
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out),
                                           variantFolders: .trustPaths)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map(relative),
                       ["out/a.jpg", "out/a_beside.jpg", "web/big/a_web.jpg", "src/a_here.jpg",
                        "src/thumbs/jpg/a_sub.jpg"])
        XCTAssertEqual(report.entries.map(\.variant), [nil, "Beside", "Web", "Here", "Sub"])
    }

    func testOtherFoldersNeverReplaceAnythingAndNeverTargetASource() async throws {
        let src = root.appendingPathComponent("src", isDirectory: true)
        let photo = try source("a.jpg", in: src)
        // Another source has the next-to-original output's name; a file already sits in the chosen folder.
        let namesake = try source("a_here.jpg", in: src)
        let web = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let existing = web.appendingPathComponent("a_web.jpg")
        try Data("keep".utf8).write(to: existing)
        let variants = [
            OutputVariant(name: "Web", nameSuffix: "_web", destination: .folder(VariantFolder(path: web.path))),
            OutputVariant(name: "Here", nameSuffix: "_here", destination: .sameFolder),
        ]
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), extraOutputs: variants)
        let before = try Data(contentsOf: namesake)
        let report = await BatchRunner.run(items([photo, namesake]), pipeline: pipeline, mode: .newFolder(out),
                                           variantFolders: .trustPaths)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map(relative),
                       ["out/a.jpg", "web/a_web_2.jpg", "src/a_here_2.jpg",
                        "out/a_here.jpg", "web/a_here_web.jpg", "src/a_here_here.jpg"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: namesake), before)
    }

    func testOverwriteModeStillNeverOverwritesWithAnExtraOutput() async throws {
        let photo = try source("a.jpg")
        let original = try Data(contentsOf: photo)
        let variants = [OutputVariant(name: "Here", settings: OutputSettings(format: .jpeg), nameSuffix: "_here",
                                      destination: .sameFolder)]
        let pipeline = Pipeline(output: OutputSettings(format: .png), extraOutputs: variants)
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .overwrite,
                                           trash: { try FileManager.default.removeItem(at: $0) })
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.png", "a_here.jpg"])
        XCTAssertNotEqual(try? Data(contentsOf: root.appendingPathComponent("a_here.jpg")), original)
    }

    func testPlannerUsesWhereTheChosenFolderIsNow() {
        let item = InputItem(source: URL(fileURLWithPath: "/src/a.jpg"), relativeDirectory: "")
        let primary = PlannedOutput(item: item, destination: URL(fileURLWithPath: "/out/a.jpg"), replacesSource: false,
                                    trashesSource: false)
        let variant = OutputVariant(name: "W", nameSuffix: "_w", destination: .folder(VariantFolder(path: "/old")))
        let planned = OutputPlanner.planVariants([VariantTarget(variants: [variant])], primaries: [primary],
                                                 folders: ["/old": URL(fileURLWithPath: "/moved", isDirectory: true)],
                                                 fileExists: { _ in false })
        XCTAssertEqual(planned.plans.first?.first?.destination.path, "/moved/a_w.jpg")
    }

    func testDryRunListsTheDestinations() async throws {
        let photo = try source("a.jpg")
        let variants = [OutputVariant(name: "Sub", nameSuffix: "_s", destination: .subfolder("small"))]
        let files = await BatchRunner.plan(items([photo]),
                                           pipeline: Pipeline(output: OutputSettings(), extraOutputs: variants),
                                           mode: .newFolder(out))
        XCTAssertEqual(files?.first?.variants.map { relative($0.destination) }, ["small/a_s.jpg"])
    }

    // MARK: Folder access

    func testAccessIsAskedForEveryExtraDestination() {
        let sources = [URL(fileURLWithPath: "/photos/one/a.jpg"), URL(fileURLWithPath: "/photos/two/b.jpg")]
        let variants = [
            OutputVariant(name: "W", nameSuffix: "_w", destination: .folder(VariantFolder(path: "/web"))),
            OutputVariant(name: "S", nameSuffix: "_s", destination: .subfolder("small")),
            OutputVariant(name: "B", nameSuffix: "_b"),
            OutputVariant(name: "N", nameSuffix: "_n", destination: .folder(VariantFolder())),
        ]
        let needs = AccessNeeds.needs(sources: sources, mode: .newFolder(URL(fileURLWithPath: "/out")),
                                      extraOutputs: variants, covered: [], caseSensitive: true)
        XCTAssertEqual(needs.map(\.folder.path), ["/out", "/photos/one", "/photos/two", "/web"])
        XCTAssertEqual(needs.map(\.purpose), [.saveToOutputFolder, .saveNextToOriginals, .saveNextToOriginals,
                                               .saveToOutputFolder])
        // Covered folders aren't asked again; without destinations nothing changes.
        XCTAssertEqual(AccessNeeds.needs(sources: sources, mode: .newFolder(URL(fileURLWithPath: "/out")),
                                         extraOutputs: variants,
                                         covered: [URL(fileURLWithPath: "/")], caseSensitive: true), [])
        XCTAssertEqual(AccessNeeds.needs(sources: sources, mode: .newFolder(URL(fileURLWithPath: "/out")),
                                         extraOutputs: [variants[2]], covered: [], caseSensitive: true).count, 1)
    }

    func testThePromptAsksForAnExtraFolder() {
        var asked: [String] = []
        let variants = [OutputVariant(name: "W", nameSuffix: "_w", destination: .folder(VariantFolder(path: "/web")))]
        let outcome = AccessPrompt.run(sources: [URL(fileURLWithPath: "/out/a.jpg")],
                                       mode: .newFolder(URL(fileURLWithPath: "/out")), extraOutputs: variants,
                                       covered: [URL(fileURLWithPath: "/out")], caseSensitive: true,
                                       ask: { need, _ in asked.append(need.folder.path); return nil }, accept: { _ in })
        XCTAssertEqual(asked, ["/web"])
        guard case .refused(let need) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(need.purpose, .saveToOutputFolder)
    }

    // MARK: Size box

    func testSizeBoxListsEveryOutput() {
        let lines = SizeEstimator.lines(
            main: SizeEstimator.MainEstimate(original: 2_000_000, bytes: 1_000_000, quality: 0.8),
            settings: OutputSettings(format: .jpeg, compression: .smart),
            variants: [VariantEstimate(name: "Thumbnail", formatName: "JPEG", bytes: 48_000, failure: nil, note: nil),
                       VariantEstimate(name: "Big", formatName: "PNG", bytes: nil, failure: "Too big", note: nil)])
        XCTAssertEqual(lines.map(\.title), ["Main JPEG", "Thumbnail JPEG", "Big PNG"])
        XCTAssertTrue(lines[0].size.contains("at 80 %"), lines[0].size)
        XCTAssertTrue(lines[0].size.hasSuffix("(\u{2212}50 %)"), lines[0].size)
        XCTAssertTrue(lines[1].size.hasSuffix("(\u{2212}98 %)"), lines[1].size)
        XCTAssertTrue(lines[2].failed)
        XCTAssertEqual(lines[2].note, "Too big")
    }
}
