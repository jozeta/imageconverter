import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class FileStepsBatchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, width: Int = 40, height: Int = 20, type: UTType = .jpeg,
                        properties: [String: Any] = [:]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: type, properties: properties)
        return url
    }

    private func contains(_ data: Data, _ secret: String) -> Bool {
        data.range(of: Data(secret.utf8)) != nil
    }

    private var out: URL { root.appendingPathComponent("out", isDirectory: true) }

    private func names(_ report: BatchReport) -> [String] { report.written.map { $0.lastPathComponent } }

    // MARK: metadata

    private var locationProps: [String: Any] {
        [kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E",
            kCGImagePropertyGPSMapDatum as String: "SECRETPLACE-42"
        ] as [String: Any],
         kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCCity as String: "SECRETCITY"]]
    }

    private func assertNoLocationLeak(options: MetadataOptions, format: OutputFormat, file: StaticString = #filePath,
                                      line: UInt = #line) async throws {
        let url = try source("loc.jpg", properties: locationProps)
        let original = try Data(contentsOf: url)
        XCTAssertTrue(contains(original, "SECRETPLACE-42"), "source must hold the secret", file: file, line: line)
        XCTAssertTrue(contains(original, "SECRETCITY"), "source must hold the secret", file: file, line: line)

        var pipeline = Pipeline(output: .init(format: format))
        pipeline.metadata = options
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.failures, [], file: file, line: line)
        let written = try XCTUnwrap(report.written.first, file: file, line: line)
        let data = try Data(contentsOf: written)
        XCTAssertNil(try TestImages.properties(of: data)[kCGImagePropertyGPSDictionary as String], file: file, line: line)
        XCTAssertFalse(contains(data, "SECRETPLACE-42"), file: file, line: line)
        XCTAssertFalse(contains(data, "SECRETCITY"), file: file, line: line)
    }

    private var cameraProps: [String: Any] {
        [kCGImagePropertyTIFFDictionary as String: [
            kCGImagePropertyTIFFModel as String: "SECRETCAM", kCGImagePropertyTIFFMake as String: "SECRETMAKE"
        ]]
    }

    private static let leakFormats: [OutputFormat] = [.jpeg, .heic, .png, .tiff, .gif]

    func testLocationNeverLeaks() async throws {
        let available = OutputFormat.available()
        for format in Self.leakFormats {
            guard available.contains(format) else {
                print("SKIP \(format): not available on this system")
                continue
            }
            for options in [MetadataOptions(isEnabled: true, removeLocation: true),
                            MetadataOptions(isEnabled: true, removeAll: true)] {
                try? FileManager.default.removeItem(at: out)
                try await assertNoLocationLeak(options: options, format: format)
            }
        }
    }

    func testCameraNeverLeaks() async throws {
        let available = OutputFormat.available()
        for format in Self.leakFormats {
            guard available.contains(format) else {
                print("SKIP \(format): not available on this system")
                continue
            }
            for options in [MetadataOptions(isEnabled: true, removeLocation: false, removeCamera: true),
                            MetadataOptions(isEnabled: true, removeAll: true)] {
                try? FileManager.default.removeItem(at: out)
                let url = try source("cam.jpg", properties: cameraProps)
                XCTAssertTrue(contains(try Data(contentsOf: url), "SECRETCAM"))
                var pipeline = Pipeline(output: .init(format: format))
                pipeline.metadata = options
                let report = await BatchRunner.run(
                    InputCollector.collect([url]), pipeline: pipeline, mode: .newFolder(out))
                XCTAssertEqual(report.failures, [], "\(format)")
                let data = try Data(contentsOf: try XCTUnwrap(report.written.first))
                XCTAssertFalse(contains(data, "SECRETCAM"), "\(format)")
                XCTAssertFalse(contains(data, "SECRETMAKE"), "\(format)")
            }
        }
    }

    // MARK: rename

    private func renamePipeline(_ pattern: String, start: Int = 1, steps: [PipelineStep] = []) -> Pipeline {
        var pipeline = Pipeline(steps: steps, output: .init(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, pattern: pattern, counterStart: start)
        return pipeline
    }

    func testBuiltInPresetsStillStripLocation() async throws {
        for preset in PresetStore.builtIns where preset.pipeline.metadata.isActive {
            try? FileManager.default.removeItem(at: out)
            let url = try source("loc.jpg", properties: locationProps)
            let report = await BatchRunner.run(
                InputCollector.collect([url]), pipeline: preset.pipeline, mode: .newFolder(out))
            XCTAssertEqual(report.failures, [], preset.name)
            let data = try Data(contentsOf: try XCTUnwrap(report.written.first))
            XCTAssertFalse(contains(data, "SECRETPLACE-42"), preset.name)
            XCTAssertNil(try TestImages.properties(of: data)[kCGImagePropertyGPSDictionary as String], preset.name)
        }
        XCTAssertEqual(PresetStore.builtIns.filter { $0.pipeline.metadata.isActive }.count, 2)
    }

    func testExcludedStepsDoNothingInBatch() async throws {
        let url = try source("keep.jpg", properties: cameraProps)
        var pipeline = Pipeline(output: .init(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, isIncluded: false, pattern: "renamed")
        pipeline.metadata = MetadataOptions(isEnabled: true, isIncluded: false, removeAll: true)
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        let written = try XCTUnwrap(report.written.first)
        XCTAssertEqual(written.deletingPathExtension().lastPathComponent, "keep")
        XCTAssertTrue(contains(try Data(contentsOf: written), "SECRETCAM"))
    }

    func testHugeCounterStartDoesNotTrap() async throws {
        let files = try (1...2).map { try source("big\($0).jpg") }
        let pipeline = renamePipeline("n{counter}", start: Int.max)
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.count, 2)
        let decoded = try JSONDecoder().decode(
            RenameOptions.self, from: Data(#"{"isEnabled":true,"counterStart":9223372036854775807}"#.utf8))
        XCTAssertEqual(decoded.counterStart, 999_999_999)
    }

    func testRenameWithCounter() async throws {
        let files = try (1...3).map { try source("img\($0).jpg") }
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: renamePipeline("trip_{counter:00}"),
                                           mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(names(report), ["trip_01.jpg", "trip_02.jpg", "trip_03.jpg"])
    }

    func testRenameCollisions() async throws {
        let files = try (1...4).map { try source("img\($0).jpg") }
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: renamePipeline("same"),
                                           mode: .newFolder(out))
        XCTAssertEqual(names(report), ["same.jpg", "same_2.jpg", "same_3.jpg", "same_4.jpg"])
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(onDisk.count, 4)
    }

    func testWidthTokenMatchesOutput() async throws {
        let url = try source("big.jpg", width: 400, height: 200)
        let step = PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(100))))
        let report = await BatchRunner.run(InputCollector.collect([url]),
                                           pipeline: renamePipeline("{width}x{height}", steps: [step]),
                                           mode: .newFolder(out))
        XCTAssertEqual(names(report), ["100x50.jpg"])
        let header = try XCTUnwrap(ImageLoader.header(of: try XCTUnwrap(report.written.first)))
        XCTAssertEqual(header.width, 100)
        XCTAssertEqual(header.height, 50)
    }

    func testSameFolderWithRenameHasNoSuffix() async throws {
        let url = try source("a.jpg")
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: renamePipeline("renamed"),
                                           mode: .sameFolder(suffix: "_converted"))
        XCTAssertEqual(report.written, [root.appendingPathComponent("renamed.jpg")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOverwriteIgnoresRenameAndReplacesInPlace() async throws {
        let url = try source("a.jpg")
        let trashed = LockedLog<URL>()
        let trash: Trasher = { trashed.append($0) }
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: renamePipeline("renamed"),
                                           mode: .overwrite, trash: trash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written, [url])
        XCTAssertEqual(trashed.values, [])
    }

    func testPlannerIgnoresMismatchedBaseNames() {
        let items = [InputItem(source: root.appendingPathComponent("a.png"), relativeDirectory: "")]
        let plans = OutputPlanner.plan(items, format: .jpeg, mode: .newFolder(out), baseNames: ["x", "y"],
                                       fileExists: { _ in false })
        XCTAssertEqual(plans.map { $0.destination.lastPathComponent }, ["a.jpg"])
    }

    func testOutputSizeFollowsEnabledSteps() {
        var disabled = PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw90)))
        disabled.isEnabled = false
        let pipe = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(100)))), disabled])
        let size = pipe.outputSize(sourceWidth: 400, sourceHeight: 200)
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 50)
    }

    // MARK: fix round 1

    func testWidthTokenUsesUprightSize() async throws {
        let url = try source("rot.jpg", width: 400, height: 200,
                             properties: [kCGImagePropertyOrientation as String: 6])
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: renamePipeline("{width}x{height}"),
                                           mode: .newFolder(out))
        XCTAssertEqual(names(report), ["200x400.jpg"])
        let header = try XCTUnwrap(ImageLoader.header(of: try XCTUnwrap(report.written.first)))
        XCTAssertEqual([header.width, header.height], [200, 400])
    }

    func testWidthTokenUprightWithCropAndResize() async throws {
        let url = try source("rot.jpg", width: 400, height: 200,
                             properties: [kCGImagePropertyOrientation as String: 6])
        let steps = [
            PipelineStep(operation: .crop(CropOptions(mode: .aspect(width: 1, height: 2)))),
            PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(100))))
        ]
        let report = await BatchRunner.run(InputCollector.collect([url]),
                                           pipeline: renamePipeline("{width}x{height}", steps: steps),
                                           mode: .newFolder(out))
        let header = try XCTUnwrap(ImageLoader.header(of: try XCTUnwrap(report.written.first)))
        XCTAssertEqual(names(report), ["\(header.width)x\(header.height).jpg"])
    }

    func testCancelledBeforePlanningWritesNothing() async throws {
        let files = try (1...3).map { try source("img\($0).jpg") }
        let task = Task { () -> BatchReport in
            while !Task.isCancelled { await Task.yield() }
            return await BatchRunner.run(InputCollector.collect(files), pipeline: renamePipeline("x_{counter}"),
                                         mode: .newFolder(out))
        }
        task.cancel()
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.written, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testTemplateNeedsHeader() {
        XCTAssertFalse(RenameTemplate("trip_{counter}_{name}").needsHeader)
        XCTAssertTrue(RenameTemplate("{width}").needsHeader)
        XCTAssertTrue(RenameTemplate("{camera}").needsHeader)
        XCTAssertTrue(RenameTemplate("{date}").needsDate)
        XCTAssertFalse(RenameTemplate("{width}").needsDate)
    }

    func testPlannerOverwriteSameNameReplacesSource() {
        let items = [InputItem(source: root.appendingPathComponent("a.jpg"), relativeDirectory: "")]
        let plans = OutputPlanner.plan(items, format: .jpeg, mode: .overwrite, baseNames: ["a"],
                                       fileExists: { _ in true })
        XCTAssertTrue(plans[0].replacesSource)
        XCTAssertFalse(plans[0].trashesSource)
    }

    func testPlannerOverwriteSwapIgnoresBaseNames() {
        let items = ["2.jpg", "1.jpg"].map { InputItem(source: root.appendingPathComponent($0), relativeDirectory: "") }
        let plans = OutputPlanner.plan(items, format: .jpeg, mode: .overwrite, baseNames: ["1", "2"],
                                       fileExists: { _ in true })
        XCTAssertEqual(plans.map { $0.destination.lastPathComponent }, ["2.jpg", "1.jpg"])
        XCTAssertTrue(plans.allSatisfy { $0.replacesSource && !$0.trashesSource })
    }
}
