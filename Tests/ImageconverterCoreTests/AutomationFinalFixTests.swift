import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// Final fix wave of round 3: Shortcuts actions' limits, History, summary, folder checks and input copies.
final class AutomationFinalFixTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func image(_ name: String, width: Int = 200, height: Int = 100, type: UTType = .jpeg) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: type)
        return url
    }

    private func outputFolder() throws -> URL {
        let url = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pixelSize(_ url: URL) throws -> (Int, Int) {
        let size = try XCTUnwrap(ImageLoader.pixelSize(of: url))
        return (size.width, size.height)
    }

    func testActionsRunWithTheBackgroundLimitsLikeJobs() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        XCTAssertEqual(Automation.limits, .background)
        XCTAssertEqual(Automation.limits.concurrency, max(1, cores / 2))
        XCTAssertEqual(Automation.limits.memoryBudgetPixels, max(1, BatchRunner.defaultMemoryBudgetPixels / 2))
        XCTAssertEqual(BatchResourceLimits(concurrency: 0, memoryBudgetPixels: 0),
                       BatchResourceLimits(concurrency: 1, memoryBudgetPixels: 1))
        // The limits reach the batch: a budget smaller than one image still converts (one at a time).
        let files = try (0..<3).map { try image("tight\($0).jpg") }
        let result = try await Automation.run(files, request: try .resize(longEdge: 50), output: try outputFolder(),
                                              limits: BatchResourceLimits(concurrency: 1, memoryBudgetPixels: 1))
        XCTAssertEqual(result.written.count, 3)
    }

    func testRunJobSummaryWording() {
        func entry(_ name: String) -> BatchResultEntry {
            BatchResultEntry(source: URL(fileURLWithPath: "/in/\(name)"),
                             destination: URL(fileURLWithPath: "/out/\(name)"), inputBytes: 10, outputBytes: 5)
        }
        var batch = BatchReport(entries: (1...12).map { entry("\($0).jpg") })
        batch.skipped = [BatchSkip(source: URL(fileURLWithPath: "/in/s.jpg"))]
        let result = JobRunResult(batch: batch, report: ProcessingReport(batch: batch, total: 13, outputMode: "newFolder"),
                                  unchanged: 0, waiting: 0, reportFile: nil, problem: nil)
        XCTAssertEqual(Automation.jobSummary(of: result, job: "Web export"),
                       "Job Web export: Converted 12 · 1 skipped by a condition")
        let plain = BatchReport(entries: (1...3).map { entry("\($0).png") })
        let again = JobRunResult(batch: plain, report: ProcessingReport(batch: plain, total: 3, outputMode: "newFolder"),
                                 unchanged: 2, waiting: 0, reportFile: nil,
                                 problem: "The report couldn't be written: full.")
        XCTAssertEqual(Automation.jobSummary(of: again, job: "Photos"),
                       "Job Photos: Converted 3 images, 2 unchanged. The report couldn't be written: full.")
    }

    func testEveryRunIsReportedForHistory() async throws {
        let files = [try image("a.jpg"), try image("b.png", type: .png)]
        var seen: [AutomationResult] = []
        let started = Date()
        let result = try await Automation.run(files, request: try .resize(longEdge: 50), output: try outputFolder(),
                                              finished: { seen.append($0) })
        XCTAssertEqual(seen, [result])
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.batch.convertedCount, 2, "both format groups in one report")
        let report = result.processingReport(request: try .resize(longEdge: 50), startedAt: started)
        XCTAssertEqual(report.summary.presetName, "Shortcuts")
        XCTAssertEqual(report.summary.succeeded, 2)
        let preset = try ExternalRequests.preset(named: "web export", in: PresetStore.builtIns)
        XCTAssertEqual(result.processingReport(request: .convert(preset: preset, format: nil), startedAt: started)
            .summary.presetName, "Shortcuts: \(preset.name)")
        // A run where every image failed is reported too; a request refused before running isn't.
        let broken = dir.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: broken)
        seen = []
        _ = try? await Automation.run([broken], request: try .resize(longEdge: 50), output: try outputFolder(),
                                      finished: { seen.append($0) })
        XCTAssertEqual(seen.first?.batch.failures.count, 1)
        seen = []
        _ = try? await Automation.run([files[0]], request: try .convertFormat(.png, qualityPercent: nil),
                                      output: try outputFolder(), writable: [.jpeg], finished: { seen.append($0) })
        XCTAssertTrue(seen.isEmpty)
    }

    func testResizeNeverEnlarges() async throws {
        let small = try image("small.jpg", width: 200, height: 100)
        let result = try await Automation.run([small], request: try .resize(longEdge: 4000), output: try outputFolder())
        let written = try XCTUnwrap(result.written.first)
        let (width, height) = try pixelSize(written)
        XCTAssertEqual(width, 200)
        XCTAssertEqual(height, 100)
    }

    func testAnExtraOutputBesideTheOriginalsNeedsTheirFolderAllowed() async throws {
        let photo = try image("p.jpg")
        let beside = OutputVariant(name: "Small", resize: .longestEdge(20), destination: .sameFolder)
        let preset = Preset(name: "Beside", pipeline: Pipeline(extraOutputs: [beside]))
        let request = AutomationRequest(preset: preset)
        do {
            _ = try await Automation.run([photo], request: request, output: try outputFolder(),
                                         isWritableFolder: { _ in false })
            XCTFail("ran without access to the original's folder")
        } catch {
            XCTAssertEqual(error as? AutomationError, .folderNotAllowed(path: dir.standardizedFileURL.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["out", "p.jpg"],
                       "nothing written")
        // Allowed: the extra output lands beside the original.
        let result = try await Automation.run([photo], request: request, output: try outputFolder(),
                                              isWritableFolder: { _ in true })
        XCTAssertEqual(result.written.map { $0.deletingLastPathComponent().standardizedFileURL },
                       [dir.appendingPathComponent("out").standardizedFileURL, dir.standardizedFileURL])
        // Outputs into a chosen folder or beside the main output need no such check.
        let plain = Pipeline(extraOutputs: [OutputVariant(name: "Small", resize: .longestEdge(20))])
        XCTAssertEqual(Automation.foldersBesideOriginals(plain, [InputItem(source: photo, relativeDirectory: "")]), [])
    }

    func testCopiesAreCappedAndRemovedAfterTheAction() throws {
        XCTAssertNoThrow(try Automation.checkCopySize(10, name: "a.jpg", limit: 10))
        XCTAssertThrowsError(try Automation.checkCopySize(11, name: "a.jpg", limit: 10)) {
            XCTAssertEqual($0 as? AutomationError, .fileTooLarge(name: "a.jpg", limit: 10))
        }
        XCTAssertEqual(Automation.maxCopiedBytes, DecodeLimits.standard.maxFileBytes)
        let alone = dir.appendingPathComponent("in/A", isDirectory: true)
        let shared = dir.appendingPathComponent("in/B", isDirectory: true)
        for folder in [alone, shared] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let copyA = alone.appendingPathComponent("a.jpg"), copyB = shared.appendingPathComponent("b.jpg")
        let output = shared.appendingPathComponent("b_small.jpg")
        for file in [copyA, copyB, output] { try Data([1]).write(to: file) }
        Automation.removeCopies([copyA, copyB])
        XCTAssertFalse(FileManager.default.fileExists(atPath: alone.path), "an emptied folder goes too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "an output beside a copy stays")
    }
}
