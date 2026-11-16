import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCLIKit
import ImageconverterCore

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    var text: String { all.joined(separator: "\n") }
}

final class CLIRunnerTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writePNG(_ name: String, width: Int = 64, height: Int = 32) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                        1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func environment(_ out: Lines, _ err: Lines, cancel: CancelToken = CancelToken()) -> CLIEnvironment {
        CLIEnvironment(out: { out.add($0) }, err: { err.add($0) },
                       presetDirectory: root.appendingPathComponent("presets"),
                       jobDirectory: root.appendingPathComponent("jobs"),
                       trash: { try FileManager.default.removeItem(at: $0) }, cancel: cancel)
    }

    private struct Outcome {
        let code: Int32
        let out: String
        let err: String
    }

    private func run(_ arguments: [String], cancel: CancelToken = CancelToken()) async -> Outcome {
        let out = Lines(), err = Lines()
        let code = await CLIRunner.main(arguments, environment: environment(out, err, cancel: cancel))
        return Outcome(code: code, out: out.text, err: err.text)
    }

    func testVersionAndUsageErrorExitCodes() async {
        let version = await run(["--version"])
        XCTAssertEqual(version.code, 0)
        XCTAssertEqual(version.out, "imageconverter \(AppInfo.version)")
        let bad = await run(["convert"])
        XCTAssertEqual(bad.code, 2)
        XCTAssertTrue(bad.err.contains("--help"))
        let refused = await run(["convert", "x.jpg", "--overwrite"])
        XCTAssertEqual(refused.code, 2)
    }

    func testEndToEndConvertWritesResizedJPEGAndJSON() async throws {
        let source = try writePNG("in.png", width: 400, height: 200)
        let outDir = root.appendingPathComponent("out")
        let result = await run(["convert", source.path, "--out", outDir.path, "--format", "jpeg", "--quality", "60",
                                "--resize-long", "100", "--strip-gps", "--json"])
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertEqual(result.err, "", "--json is quiet")
        let written = outDir.appendingPathComponent("in.jpg")
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 100)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        let summary = try XCTUnwrap(json["summary"] as? [String: Any])
        XCTAssertEqual(summary["succeeded"] as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original is untouched")
    }

    func testDryRunWritesNothing() async throws {
        let source = try writePNG("in.png")
        let outDir = root.appendingPathComponent("never")
        let result = await run(["convert", source.path, "--out", outDir.path, "--dry-run"])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.out.contains("in.jpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path))
        let same = await run(["convert", source.path, "--same-folder", "--format", "png", "--dry-run"])
        XCTAssertEqual(same.code, 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(files, ["in.png"])
    }

    func testNothingToDoAndFailures() async throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let none = await run(["convert", empty.path, "--out", root.appendingPathComponent("o").path, "--quiet"])
        XCTAssertEqual(none.code, 3)
        let corrupt = root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: corrupt)
        let failed = await run(["convert", corrupt.path, "--out", root.appendingPathComponent("o2").path, "--quiet"])
        XCTAssertEqual(failed.code, 1)
        XCTAssertTrue(failed.out.contains("failed:"))
    }

    func testPresetPipelineFileAndSameFolder() async throws {
        let source = try writePNG("pic.png")
        let missing = await run(["convert", source.path, "--preset", "Nope", "--same-folder"])
        XCTAssertEqual(missing.code, 2)
        let builtIn = await run(["convert", source.path, "--preset", "archive tiff", "--same-folder", "--suffix", "_t",
                                 "--quiet"])
        XCTAssertEqual(builtIn.code, 0, builtIn.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("pic.tif").path))
        let file = root.appendingPathComponent("p.json")
        try JSONEncoder().encode(Pipeline(output: OutputSettings(format: .png))).write(to: file)
        let viaFile = await run(["convert", source.path, "--pipeline", file.path, "--out",
                                 root.appendingPathComponent("o").path, "--report", "csv", "--quiet"])
        XCTAssertEqual(viaFile.code, 0, viaFile.err)
        XCTAssertTrue(viaFile.out.hasPrefix("\"source\""))
        try Data("{\"hello\":1}".utf8).write(to: file)
        let bad = await run(["convert", source.path, "--pipeline", file.path, "--same-folder"])
        XCTAssertEqual(bad.code, 2)
    }

    func testPresetsList() async {
        let plain = await run(["presets", "list"])
        XCTAssertTrue(plain.out.contains("Web export (built-in)"))
        let json = await run(["presets", "list", "--json"])
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(json.out.utf8)))
    }

    func testJobsListAndRun() async throws {
        let inputs = root.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        _ = try writePNG("watched/a.png")
        // The job runner only takes files that have settled for a couple of seconds.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: inputs.appendingPathComponent("a.png").path)
        let store = JobStore(directory: root.appendingPathComponent("jobs"))
        let jobOut = root.appendingPathComponent("jobout")
        try store.save(Job(name: "Nightly", pipeline: Pipeline(output: OutputSettings(format: .png), extraOutputs: [
            OutputVariant(name: "thumb", settings: OutputSettings(format: .png), resize: .longestEdge(8),
                          nameSuffix: "_thumb"),
        ]), inputs: [inputs], output: .newFolder(jobOut)))
        let list = await run(["jobs", "list"])
        XCTAssertEqual(list.out, "Nightly")
        let ran = await run(["jobs", "run", "nightly", "--quiet"])
        XCTAssertEqual(ran.code, 0, ran.err)
        XCTAssertTrue(ran.err.contains("Extra output “thumb” → \(jobOut.standardizedFileURL.path)"), ran.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("jobout/a.png").path))
        let unknown = await run(["jobs", "run", "ghost"])
        XCTAssertEqual(unknown.code, 2)
    }

    func testDryRunEvaluatesConditionsAndRenameLikeTheBatch() async throws {
        let big = try writePNG("big.png", width: 400, height: 200)
        let small = try writePNG("small.png")
        let condition = ConditionalStep(conditions: [.longestEdge(.greaterThan, 100)], then: [.skip])
        let pipeline = Pipeline(
            steps: [PipelineStep(operation: .condition(condition))], output: OutputSettings(format: .png),
            rename: RenameOptions(isEnabled: true, pattern: "img_{seq}"))
        let file = root.appendingPathComponent("p.json")
        try JSONEncoder().encode(pipeline).write(to: file)
        let outDir = root.appendingPathComponent("planned")
        let result = await run(["convert", big.path, small.path, "--pipeline", file.path, "--out", outDir.path,
                                "--dry-run", "--report", "csv"])
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertTrue(result.out.contains("img_1.png"), result.out)
        XCTAssertTrue(result.out.contains("\"skipped\""), "the big file is reported as skipped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path))
    }

    /// `--strip-gps --strip-all` are a floor a condition's metadata override or copy can't lower (review C1).
    func testStripFlagsWinOverConditionOverridesAndCopies() async throws {
        let url = root.appendingPathComponent("gps.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                                        1, nil))
        let gps: [String: Any] = [kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E"
        ] as [String: Any]]
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            XCTUnwrap(CGImageSourceCreateWithURL(writePNG("seed.png") as CFURL, nil)), 0, nil))
        CGImageDestinationAddImage(destination, image, gps as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        for (index, branch) in [[ConditionalAction.metadata(MetadataOptions(location: .keep, artist: "A"))],
                                [.copyOriginal]].enumerated() {
            let condition = ConditionalStep(conditions: [.hasGPS(true)], then: branch)
            let pipeline = Pipeline(steps: [PipelineStep(operation: .condition(condition))],
                                    output: OutputSettings(format: .jpeg))
            let file = root.appendingPathComponent("p\(index).json")
            try JSONEncoder().encode(pipeline).write(to: file)
            let outDir = root.appendingPathComponent("floor\(index)")
            let result = await run(["convert", url.path, "--pipeline", file.path, "--out", outDir.path,
                                    "--strip-gps", "--strip-all", "--quiet"])
            XCTAssertEqual(result.code, 0, result.err)
            let written = outDir.appendingPathComponent("gps.jpg")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String], "branch \(index) kept the location")
        }
    }

    /// Re-review N2: `--strip-all` removes everything, even what the preset's "keep when removing all" list names.
    func testStripAllIgnoresThePresetsKeepList() async throws {
        let url = root.appendingPathComponent("keep.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                                        1, nil))
        let gps: [String: Any] = [kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E"
        ] as [String: Any]]
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            XCTUnwrap(CGImageSourceCreateWithURL(writePNG("seed2.png") as CFURL, nil)), 0, nil))
        CGImageDestinationAddImage(destination, image, gps as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var metadata = MetadataOptions(isEnabled: true, location: .keep)
        metadata.keepWhenRemovingAll = [.location, .copyright]
        let file = root.appendingPathComponent("keep.json")
        try JSONEncoder().encode(Pipeline(output: OutputSettings(format: .jpeg), metadata: metadata)).write(to: file)
        let outDir = root.appendingPathComponent("stripall")
        let result = await run(["convert", url.path, "--pipeline", file.path, "--out", outDir.path, "--strip-all",
                                "--quiet"])
        XCTAssertEqual(result.code, 0, result.err)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outDir.appendingPathComponent("keep.jpg") as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertEqual(ConvertCommand.applyOverrides(try CLIParser.parseConvert(["x", "--strip-all", "--out", "o"]),
                                                     to: Pipeline(metadata: metadata)).metadata.keepWhenRemovingAll, [])
    }

    func testWarnsWhenFlagsDoNotApplyToFormat() async throws {
        let source = try writePNG("w.png")
        let result = await run(["convert", source.path, "--out", root.appendingPathComponent("o").path,
                                "--format", "png", "--quality", "50", "--max-size", "10KB", "--quiet"])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.err.contains("--quality has no effect on PNG"))
        XCTAssertTrue(result.err.contains("--max-size has no effect on PNG"))
    }

    func testMissingInputIsReportedAndCounted() async throws {
        let source = try writePNG("ok.png")
        let ghost = root.appendingPathComponent("ghost.png").path
        let result = await run(["convert", source.path, ghost, "--out", root.appendingPathComponent("o").path,
                                "--quiet"])
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.err.contains("No such file: \(ghost)"))
        XCTAssertTrue(result.out.contains("2 files") || result.out.contains("1 of 2"), result.out)
        let onlyGhost = await run(["convert", ghost, "--out", root.appendingPathComponent("o").path])
        XCTAssertEqual(onlyGhost.code, 1)
    }

    /// Deterministic (parked T30): the first finished file pauses the batch, so no further file can start and the
    /// run can't reach the end before the cancel arrives.
    func testCancellationStopsCleanlyAndExits130() async throws {
        let count = 40
        for index in 0..<count { _ = try writePNG("c\(index).png", width: 600, height: 400) }
        let outDir = root.appendingPathComponent("cancelled")
        let token = CancelToken()
        let gate = BatchControl()
        let out = Lines(), err = Lines()
        var environment = CLIEnvironment(
            out: { out.add($0) }, err: { line in
                err.add(line)
                if line.hasPrefix("[1/") {
                    gate.pause()
                    token.cancel()
                }
            },
            presetDirectory: root.appendingPathComponent("presets"), jobDirectory: root.appendingPathComponent("jobs"),
            trash: { try FileManager.default.removeItem(at: $0) }, cancel: token)
        environment.control = gate
        let inputs = (0..<count).map { root.appendingPathComponent("c\($0).png").path }
        let code = await CLIRunner.main(["convert"] + inputs + ["--out", outDir.path, "--format", "png"],
                                        environment: environment)
        XCTAssertEqual(code, 130, err.text)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        XCTAssertTrue(leftovers.allSatisfy { $0.hasSuffix(".png") }, "no temp files left: \(leftovers)")
        XCTAssertTrue(err.text.contains("Interrupted"))
        let already = CancelToken()
        already.cancel()
        let early = await run(["convert", inputs[0], "--out", outDir.path, "--quiet"], cancel: already)
        XCTAssertEqual(early.code, 130)
    }
}

extension CLIRunnerTests {
    /// A condition's "Save into subfolder" shows in the dry run and is where the real run writes; a preset applied
    /// by a condition comes from the command line's presets folder.
    func testDryRunAndRunShowConditionSubfoldersAndPresets() async throws {
        let photo = try writePNG("photo.png")
        let store = PresetStore(directory: root.appendingPathComponent("presets"))
        let preset = Preset(name: "As JPEG", pipeline: Pipeline(output: OutputSettings(format: .jpeg)))
        try store.save(preset)
        let condition = ConditionalStep(conditions: [.width(.atLeast, 1)],
                                        then: [.subfolder("Wide/{format}"), .preset(PresetLink(preset))])
        let pipeline = Pipeline(steps: [PipelineStep(operation: .condition(condition))], output: OutputSettings(format: .png))
        let file = root.appendingPathComponent("p.json")
        try JSONEncoder().encode(pipeline).write(to: file)
        let outDir = root.appendingPathComponent("planned")
        let dry = await run(["convert", photo.path, "--pipeline", file.path, "--out", outDir.path, "--dry-run"])
        XCTAssertEqual(dry.code, 0, dry.err)
        XCTAssertTrue(dry.out.contains("planned/Wide/JPEG/photo.jpg"), dry.out)
        let real = await run(["convert", photo.path, "--pipeline", file.path, "--out", outDir.path])
        XCTAssertEqual(real.code, 0, real.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("Wide/JPEG/photo.jpg").path))
    }
}

extension CLIRunnerTests {
    /// Task 7: `--overwrite --yes` with a pipeline's rename plans the renamed destinations; the dry run marks them
    /// "replace (original to Trash)" (an unchanged name and format: "replace"), and the real run does just that.
    func testOverwriteWithRenameDryRunAndRun() async throws {
        let first = try writePNG("a.png")
        let second = try writePNG("b.png")
        var rename = RenameOptions(isEnabled: true, pattern: "{name}")
        rename.replacements = [ReplacementRule(find: "a", replace: "renamed")]
        let pipeline = Pipeline(output: OutputSettings(format: .png), rename: rename)
        let file = root.appendingPathComponent("p.json")
        try JSONEncoder().encode(pipeline).write(to: file)
        let dry = await run(["convert", first.path, second.path, "--pipeline", file.path, "--overwrite", "--yes",
                             "--dry-run"])
        XCTAssertEqual(dry.code, 0, dry.err)
        let renamed = root.appendingPathComponent("renamed.png")
        let lines = dry.out.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("a.png -> ") && $0.hasSuffix("/renamed.png (replace (original to Trash))") },
                      dry.out)
        XCTAssertTrue(lines.contains { $0.contains("b.png -> ") && $0.hasSuffix("/b.png (replace)") }, dry.out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "a dry run writes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))

        let real = await run(["convert", first.path, second.path, "--pipeline", file.path, "--overwrite", "--yes"])
        XCTAssertEqual(real.code, 0, real.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the original went to the (test) Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
