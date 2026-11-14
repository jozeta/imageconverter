import XCTest
@testable import ImageconverterCore

/// Task 7: "Overwrite original files" with the Rename step. The renamed result goes into the source's own folder;
/// the original is replaced in place when the path is unchanged, otherwise moved to the Trash after the new file is
/// saved. No other file is ever replaced.
final class OverwriteRenameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, width: Int = 40) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: 20), to: url, type: .jpeg)
        return url
    }

    private func renamePipeline(_ pattern: String) -> Pipeline {
        var pipeline = Pipeline(output: .init(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, pattern: pattern)
        return pipeline
    }

    /// Trashes for real (removes the file) and records what it was asked to trash.
    private func recordingTrash() -> (Trasher, LockedLog<URL>) {
        let log = LockedLog<URL>()
        return ({ url in
            log.append(url)
            try FileManager.default.removeItem(at: url)
        }, log)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: planner

    private func item(_ name: String) -> InputItem {
        InputItem(source: URL(fileURLWithPath: "/src/\(name)"), relativeDirectory: "")
    }

    func testPlannerRenamesIntoTheSourceFolderAndTrashes() {
        let plans = OutputPlanner.plan([item("a.jpg"), item("b.heic")], format: .jpeg, mode: .overwrite,
                                       baseNames: ["x", "y"], fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/x.jpg", "/src/y.jpg"])
        XCTAssertEqual(plans.map(\.replacesSource), [false, false])
        XCTAssertEqual(plans.map(\.trashesSource), [true, true])
    }

    func testPlannerSameNameStaysInPlace() {
        let plans = OutputPlanner.plan([item("a.jpg"), item("B.JPEG")], format: .jpeg, mode: .overwrite,
                                       baseNames: ["a", "B"], fileExists: { _ in true })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/a.jpg", "/src/B.JPEG"])
        XCTAssertEqual(plans.map(\.replacesSource), [true, true])
        XCTAssertEqual(plans.map(\.trashesSource), [false, false])
    }

    func testPlannerRenameOntoAnotherBatchSourceGetsNumber() {
        // a → b while b.jpg is in the batch too (and is itself renamed to c).
        let plans = OutputPlanner.plan([item("a.jpg"), item("b.jpg")], format: .jpeg, mode: .overwrite,
                                       baseNames: ["b", "c"], fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.lastPathComponent), ["b_2.jpg", "c.jpg"])
        XCTAssertTrue(plans.allSatisfy { $0.trashesSource && !$0.replacesSource })
    }

    func testPlannerSwapNeverReplacesTheOtherOriginal() {
        let sources: Set<String> = ["/src/2.jpg", "/src/1.jpg"]
        let plans = OutputPlanner.plan([item("2.jpg"), item("1.jpg")], format: .jpeg, mode: .overwrite,
                                       baseNames: ["1", "2"], fileExists: { sources.contains($0.path) })
        XCTAssertEqual(plans.map(\.destination.lastPathComponent), ["1_2.jpg", "2_2.jpg"])
        XCTAssertTrue(plans.allSatisfy { $0.trashesSource && !$0.replacesSource })
    }

    func testPlannerTwoItemsToTheSameNameGetNumbers() {
        let plans = OutputPlanner.plan([item("a.jpg"), item("b.png")], format: .jpeg, mode: .overwrite,
                                       baseNames: ["same", "same"], fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.lastPathComponent), ["same.jpg", "same_2.jpg"])
    }

    func testPlannerOverwriteStillIgnoresSubfolders() {
        let target = OutputTarget(item: item("a.jpg"), format: .jpeg, baseName: "x", subfolder: ["Sorted"])
        let plans = OutputPlanner.plan([target], mode: .overwrite, fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/x.jpg"])
    }

    func testPlannerRenamedCopyOfOriginalMovesUnderTheNewName() {
        let plain = OutputPlanner.plan([.copyOfOriginal(item("a.png"))], mode: .overwrite, fileExists: { _ in true })
        XCTAssertEqual(plain.map(\.destination.path), ["/src/a.png"])
        XCTAssertEqual(plain.map(\.replacesSource), [true], "a copy without a new name stays a no-op")
        let renamed = OutputPlanner.plan([.copyOfOriginal(item("a.png"), baseName: "x")], mode: .overwrite,
                                         fileExists: { _ in false })
        XCTAssertEqual(renamed.map(\.destination.path), ["/src/x.png"])
        XCTAssertEqual(renamed.map(\.trashesSource), [true])
    }

    // MARK: batch

    func testRenameWritesTheNewNameAndTrashesTheOriginal() async throws {
        let url = try source("a.jpg")
        let (trash, trashed) = recordingTrash()
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: renamePipeline("renamed"),
                                           mode: .overwrite, trash: trash)
        let renamed = root.appendingPathComponent("renamed.jpg")
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written, [renamed])
        XCTAssertEqual(trashed.values, [url])
        XCTAssertTrue(exists(renamed))
        XCTAssertFalse(exists(url))
    }

    func testRenameToTheSameNameReplacesInPlace() async throws {
        let url = try source("a.jpg", width: 40)
        var pipeline = renamePipeline("{name}")
        pipeline.steps = [PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(10))))]
        let (trash, trashed) = recordingTrash()
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: pipeline, mode: .overwrite,
                                           trash: trash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written, [url])
        XCTAssertEqual(trashed.values, [])
        XCTAssertEqual(ImageLoader.header(of: url)?.width, 10)
    }

    func testClashWithAnUnrelatedFileGetsNumberAndLeavesItAlone() async throws {
        let url = try source("a.jpg")
        let unrelated = try source("taken.jpg", width: 33)
        let before = try Data(contentsOf: unrelated)
        let (trash, trashed) = recordingTrash()
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: renamePipeline("taken"),
                                           mode: .overwrite, trash: trash)
        XCTAssertEqual(report.written, [root.appendingPathComponent("taken_2.jpg")])
        XCTAssertEqual(try Data(contentsOf: unrelated), before)
        XCTAssertEqual(trashed.values, [url])
    }

    func testRenameOntoAnotherItemOfTheBatchGetsNumberAndTheOtherIsProcessed() async throws {
        let first = try source("a.jpg", width: 40)
        let second = try source("b.jpg", width: 30)
        // Only a.jpg is renamed (to b); b.jpg keeps its name, so it is replaced in place.
        var pipeline = renamePipeline("{name}")
        pipeline.steps = [PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(20))))]
        pipeline.rename.replacements = [ReplacementRule(find: "a", replace: "b")]
        let (trash, trashed) = recordingTrash()
        let report = await BatchRunner.run(InputCollector.collect([first, second]), pipeline: pipeline,
                                           mode: .overwrite, trash: trash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(Set(report.written.map(\.lastPathComponent)), ["b_2.jpg", "b.jpg"])
        XCTAssertEqual(trashed.values, [first])
        XCTAssertEqual(ImageLoader.header(of: second)?.width, 20, "b.jpg was processed in place, not overwritten by a")
        XCTAssertEqual(ImageLoader.header(of: root.appendingPathComponent("b_2.jpg"))?.width, 20)
    }

    func testTwoItemsRenamedToTheSameNameGetNumbers() async throws {
        let files = [try source("a.jpg"), try source("b.jpg")]
        let (trash, trashed) = recordingTrash()
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: renamePipeline("same"),
                                           mode: .overwrite, trash: trash)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(Set(report.written.map(\.lastPathComponent)), ["same.jpg", "same_2.jpg"])
        XCTAssertEqual(Set(trashed.values), Set(files))
    }

    func testDryRunPlanShowsRenamedDestinations() async throws {
        let url = try source("a.jpg")
        let result = await BatchRunner.plan(InputCollector.collect([url]), pipeline: renamePipeline("renamed"),
                                            mode: .overwrite)
        let planned = try XCTUnwrap(result)
        XCTAssertEqual(planned.map(\.destination), [root.appendingPathComponent("renamed.jpg")])
        XCTAssertEqual(planned.map(\.trashesSource), [true])
        XCTAssertEqual(planned.map(\.replacesSource), [false])
    }

    /// The existing (milestone 4) behaviour when a run stops between the commit and the trash: the new file and
    /// the untouched original are both there. A resume treats the unchanged original as still to do; the batch
    /// then never replaces the earlier result (it gets `_2`), so nothing is lost, at the cost of one duplicate.
    func testResumeAfterAStopBetweenCommitAndTrashNeverReplacesTheResult() async throws {
        let url = try source("a.jpg")
        // As left by the interrupted run: renamed.jpg was committed, a.jpg not yet trashed.
        let earlier = try source("renamed.jpg", width: 21)
        let before = try Data(contentsOf: earlier)
        let journal = RunJournal(items: InputCollector.collect([url]), pipeline: renamePipeline("renamed"),
                                 mode: .overwrite, started: Date().addingTimeInterval(-60), bookmarker: { _ in nil })
        let resume = ResumePlan.make(journal: journal, existing: [], fileExists: { FileManager.default.fileExists(atPath: $0) },
                                     directoryExists: { _ in true })
        XCTAssertEqual(resume.toRun.map(\.source), [url], "the original is unchanged, so it is still to do")
        let (trash, _) = recordingTrash()
        let report = await BatchRunner.run(resume.toRun, pipeline: resume.pipeline, mode: resume.mode, trash: trash)
        XCTAssertEqual(report.written, [root.appendingPathComponent("renamed_2.jpg")])
        XCTAssertEqual(try Data(contentsOf: earlier), before)
        XCTAssertFalse(exists(url))
    }

    /// A trashed original is gone, so the journal's resume lists it as missing, never as to do again.
    func testResumeAfterTheOriginalWasTrashedDoesNotReprocessIt() throws {
        let url = try source("a.jpg")
        let journal = RunJournal(items: InputCollector.collect([url]), pipeline: renamePipeline("renamed"),
                                 mode: .overwrite, bookmarker: { _ in nil })
        try FileManager.default.removeItem(at: url)
        let resume = ResumePlan.make(journal: journal, existing: [], fileExists: { FileManager.default.fileExists(atPath: $0) },
                                     directoryExists: { _ in true })
        XCTAssertEqual(resume.toRun, [])
        XCTAssertEqual(resume.missing, [url])
    }
}

extension OverwriteRenameTests {
    /// Task 7 fix round 1: a failed Trash after the commit is a written file with a warning, not a failure.
    func testTrashFailureReportsTheSavedFileWithAWarning() async throws {
        let url = try source("a.jpg")
        let failingTrash: Trasher = { _ in throw CocoaError(.fileWriteNoPermission) }
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: renamePipeline("renamed"),
                                           mode: .overwrite, trash: failingTrash)
        let renamed = root.appendingPathComponent("renamed.jpg")
        XCTAssertEqual(report.written, [renamed])
        XCTAssertEqual(report.failures, [])
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertEqual(entry.destination, renamed)
        XCTAssertTrue(entry.note?.hasPrefix(FileCommitter.trashFailurePrefix) == true, "\(entry.note ?? "")")
        XCTAssertEqual(report.notes.map(\.source), [url])
        XCTAssertGreaterThan(entry.outputBytes, 0)
        XCTAssertTrue(exists(url), "the original stays when the Trash fails")
    }

    /// The live progress and item events agree with the report: a failed Trash ends as done, not failed.
    func testTrashFailureEndsAsDoneInTheLiveProgress() async throws {
        let url = try source("a.jpg")
        let failingTrash: Trasher = { _ in throw CocoaError(.fileWriteNoPermission) }
        let progress = LockedLog<BatchProgress>()
        let stages = LockedLog<ItemEvent.Stage>()
        _ = await BatchRunner.run(InputCollector.collect([url]), pipeline: renamePipeline("renamed"), mode: .overwrite,
                                  trash: failingTrash, progress: { progress.append($0) }, events: { stages.append($0.stage) })
        XCTAssertEqual(progress.last, BatchProgress(completed: 1, failed: 0, total: 1))
        XCTAssertEqual(stages.last, .done)
        XCTAssertFalse(stages.values.contains { if case .failed = $0 { return true } else { return false } })
    }
}
