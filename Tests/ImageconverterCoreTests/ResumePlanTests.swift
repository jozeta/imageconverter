import XCTest
@testable import ImageconverterCore

final class ResumePlanTests: XCTestCase {
    private func item(_ name: String) -> InputItem {
        InputItem(source: URL(fileURLWithPath: "/photos/\(name)"), relativeDirectory: "")
    }

    private func journal(_ names: [String], completed: [Int], mode: OutputMode = .sameFolder(suffix: "_new")) -> RunJournal {
        var journal = RunJournal(items: names.map(item), pipeline: Pipeline(), mode: mode)
        journal.completed = completed
        return journal
    }

    func testRunsTheRemainingPresentItemsAndListsMissingOnes() {
        let plan = ResumePlan.make(journal: journal(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], completed: [0]),
                                   existing: [], isReadable: { !$0.hasSuffix("c.jpg") }, directoryExists: { _ in true })
        XCTAssertEqual(plan.toRun.map(\.source.lastPathComponent), ["b.jpg", "d.jpg"])
        XCTAssertEqual(plan.missing.map(\.lastPathComponent), ["c.jpg"])
        XCTAssertNil(plan.problem)
        XCTAssertFalse(plan.needsOverwriteConfirmation)
    }

    func testAddsOnlyItemsNotAlreadyInTheList() {
        let plan = ResumePlan.make(journal: journal(["a.jpg", "b.jpg", "c.jpg"], completed: []),
                                   existing: [item("b.jpg")], isReadable: { _ in true }, directoryExists: { _ in true })
        XCTAssertEqual(plan.toAdd.map(\.source.lastPathComponent), ["a.jpg", "c.jpg"])
        XCTAssertEqual(plan.toRun.count, 3)
    }

    func testNothingLeftWhenEverythingIsDoneOrMissing() {
        let plan = ResumePlan.make(journal: journal(["a.jpg", "b.jpg"], completed: [0]),
                                   existing: [], isReadable: { _ in false }, directoryExists: { _ in true })
        XCTAssertEqual(plan.problem, .nothingLeft)
        XCTAssertTrue(plan.toRun.isEmpty)
    }

    func testMissingOutputFolder() {
        let folder = URL(fileURLWithPath: "/out", isDirectory: true)
        let plan = ResumePlan.make(journal: journal(["a.jpg"], completed: [], mode: .newFolder(folder)),
                                   existing: [], isReadable: { _ in true }, directoryExists: { _ in false })
        XCTAssertEqual(plan.problem, .outputFolderMissing(folder))
    }

    func testOverwriteNeedsConfirmationAndKeepsTheJournalMode() {
        let plan = ResumePlan.make(journal: journal(["a.jpg"], completed: [], mode: .overwrite),
                                   existing: [], isReadable: { _ in true }, directoryExists: { _ in true })
        XCTAssertTrue(plan.needsOverwriteConfirmation)
        XCTAssertEqual(plan.mode, .overwrite)
    }

    func testOverwriteSkipsSourcesThatChangedSinceTheStart() {
        let names = ["a.jpg", "b.jpg", "c.jpg"]
        let started = Date(timeIntervalSince1970: 1_000)
        var journal = RunJournal(items: names.map(item), pipeline: Pipeline(), mode: .overwrite, started: started,
                                 fingerprint: { FileFingerprint(path: $0.path, size: 10, modified: 500) })
        journal.items[2].size = nil
        journal.items[2].modified = nil
        let now: [String: FileFingerprint] = [
            "/photos/a.jpg": FileFingerprint(path: "/photos/a.jpg", size: 10, modified: 500),
            "/photos/b.jpg": FileFingerprint(path: "/photos/b.jpg", size: 12, modified: 1_100),
            // No fingerprint recorded (an older journal): modified after the start counts as replaced.
            "/photos/c.jpg": FileFingerprint(path: "/photos/c.jpg", size: 10, modified: 1_200)
        ]
        let plan = ResumePlan.make(journal: journal, existing: [], isReadable: { _ in true },
                                   directoryExists: { _ in true }, fingerprint: { now[$0] })
        XCTAssertEqual(plan.toRun.map(\.source.lastPathComponent), ["a.jpg"])
        XCTAssertEqual(plan.alreadyReplaced.map(\.lastPathComponent), ["b.jpg", "c.jpg"])

        // Outside overwrite mode sources never change, so nothing is checked.
        let other = ResumePlan.make(journal: self.journal(names, completed: []), existing: [], isReadable: { _ in true },
                                    directoryExists: { _ in true }, fingerprint: { now[$0] })
        XCTAssertEqual(other.toRun.count, 3)
        XCTAssertEqual(other.alreadyReplaced, [])
    }

    /// Final review I3: one file listed twice (loose and through its folder, or in another case) runs once.
    func testDuplicatesByPathRunOnce() {
        var journal = journal(["a.jpg"], completed: [])
        journal.items.append(.init(path: "/photos/a.jpg", relativeDirectory: "photos"))
        journal.items.append(.init(path: "/photos/A.JPG", relativeDirectory: ""))
        let plan = ResumePlan.make(journal: journal, existing: [InputItem(source: URL(fileURLWithPath: "/photos/a.jpg"),
                                                                           relativeDirectory: "photos")],
                                   isReadable: { _ in true }, directoryExists: { _ in true })
        XCTAssertEqual(plan.toRun.count, 1)
        XCTAssertEqual(plan.toAdd, [], "already in the list through its folder")
    }

    func testModeDescriptions() {
        XCTAssertEqual(ResumePlan.describe(.overwrite), "overwrite the original files")
        XCTAssertEqual(ResumePlan.describe(.sameFolder(suffix: "_new")), "the same folder as each original (suffix _new)")
        XCTAssertEqual(ResumePlan.describe(.newFolder(URL(fileURLWithPath: "/x/Out"))), "the folder Out")
    }

    func testPausableClockExcludesPausedTime() {
        let now = Box()
        let clock = PausableClock { now.value }
        now.value = 10
        XCTAssertEqual(clock.now(), 10)
        clock.pause()
        now.value = 25
        XCTAssertEqual(clock.now(), 10)
        clock.pause()  // twice is the same as once
        clock.resume()
        now.value = 30
        XCTAssertEqual(clock.now(), 15)
        clock.resume()  // not paused: nothing changes
        XCTAssertEqual(clock.now(), 15)
    }

    func testMetricsRateIgnoresPausedTime() {
        let now = Box()
        let clock = PausableClock { now.value }
        var metrics = RunMetrics(sourcePixels: [1, 1, 1, 1]) { clock.now() }
        now.value = 2
        metrics.record(ItemEvent(index: 0, source: URL(fileURLWithPath: "/a"), stage: .done))
        clock.pause()
        now.value = 1000
        clock.resume()
        XCTAssertEqual(metrics.snapshot().elapsed, 2, accuracy: 0.001)
    }
}

private final class Box: @unchecked Sendable {
    var value: TimeInterval = 0
}
