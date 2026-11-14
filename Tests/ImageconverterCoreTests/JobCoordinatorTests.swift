import XCTest
@testable import ImageconverterCore

final class JobCoordinatorTests: XCTestCase {
    private let jobA = UUID()
    private let jobB = UUID()
    private let file = URL(fileURLWithPath: "/in/a.jpg")
    private let other = URL(fileURLWithPath: "/in/b.jpg")
    private var allowed: Set<UUID> = []

    override func setUp() {
        allowed = [jobA, jobB]
    }

    private func may(_ id: UUID) -> Bool { allowed.contains(id) }

    func testTriggersDuringARunBecomeOneFollowUp() {
        var coordinator = JobCoordinator()
        XCTAssertEqual(coordinator.request(jobA, .scan, origin: .automatic, allowed: may), [.start(jobA, .scan, .automatic)])
        XCTAssertEqual(coordinator.request(jobA, .files([file]), origin: .automatic, allowed: may), [])
        XCTAssertEqual(coordinator.request(jobA, .files([other]), origin: .automatic, allowed: may), [])
        XCTAssertTrue(coordinator.isQueued(jobA))
        XCTAssertEqual(coordinator.finished(jobA, allowed: may), [.start(jobA, .files([file, other]), .automatic)])
        XCTAssertEqual(coordinator.finished(jobA, allowed: may), [])
        XCTAssertFalse(coordinator.isActive(jobA))
    }

    func testOnlyOneJobBatchAtATimeAcrossJobs() {
        var coordinator = JobCoordinator(maxActive: 1)
        _ = coordinator.request(jobA, .scan, origin: .automatic, allowed: may)
        XCTAssertEqual(coordinator.request(jobB, .scan, origin: .automatic, allowed: may), [])
        XCTAssertEqual(coordinator.active, [jobA])
        // A's follow-up came after B: B goes first.
        _ = coordinator.request(jobA, .scan, origin: .automatic, allowed: may)
        XCTAssertEqual(coordinator.finished(jobA, allowed: may), [.start(jobB, .scan, .automatic)])
        XCTAssertEqual(coordinator.finished(jobB, allowed: may), [.start(jobA, .scan, .automatic)])
    }

    func testPauseOrSwitchOffDropsAutomaticFollowUpsButNotRunNow() {
        var coordinator = JobCoordinator()
        _ = coordinator.request(jobA, .scan, origin: .automatic, allowed: may)
        _ = coordinator.request(jobA, .files([file]), origin: .automatic, allowed: may)
        _ = coordinator.request(jobB, .scan, origin: .user, allowed: may)
        allowed = []  // Pause all
        coordinator.prune(allowed: may)
        XCTAssertFalse(coordinator.isQueued(jobA))
        XCTAssertTrue(coordinator.isQueued(jobB))
        // Automatic requests while paused are ignored; the user's run still starts when A ends.
        XCTAssertEqual(coordinator.request(jobA, .scan, origin: .automatic, allowed: may), [])
        XCTAssertEqual(coordinator.finished(jobA, allowed: may), [.start(jobB, .scan, .user)])
    }

    func testFinishedChecksWhetherTheFollowUpMayStillRun() {
        var coordinator = JobCoordinator()
        _ = coordinator.request(jobA, .scan, origin: .automatic, allowed: may)
        _ = coordinator.request(jobA, .scan, origin: .automatic, allowed: may)
        allowed.remove(jobA)  // switched off without a prune
        XCTAssertEqual(coordinator.finished(jobA, allowed: may), [])
        XCTAssertFalse(coordinator.isActive(jobA))
    }

    func testAUserRequestMergedWithAutomaticKeepsTheUserOrigin() {
        var coordinator = JobCoordinator()
        _ = coordinator.request(jobA, .scan, origin: .automatic, allowed: may)
        _ = coordinator.request(jobA, .files([file]), origin: .user, allowed: may)
        _ = coordinator.request(jobA, .files([other]), origin: .automatic, allowed: may)
        XCTAssertEqual(coordinator.pendingOrigin(jobA), .user)
        allowed = []
        XCTAssertEqual(coordinator.finished(jobA, allowed: may), [.start(jobA, .files([file, other]), .user)])
    }

    func testDeleteDropsEverythingWaiting() {
        var coordinator = JobCoordinator()
        _ = coordinator.request(jobA, .scan, origin: .user, allowed: may)
        _ = coordinator.request(jobA, .scan, origin: .user, allowed: may)
        coordinator.rearmWhenIdle(jobA)
        coordinator.drop(jobA)
        XCTAssertEqual(coordinator.finished(jobA, allowed: may), [])
    }

    func testALaunchFailureFreesTheSlot() {
        var coordinator = JobCoordinator()
        _ = coordinator.request(jobA, .scan, origin: .user, allowed: may)
        _ = coordinator.request(jobB, .scan, origin: .user, allowed: may)
        // A couldn't start (its folder is gone): reported as finished, B starts, A is idle.
        XCTAssertEqual(coordinator.finished(jobA, allowed: may), [.start(jobB, .scan, .user)])
        XCTAssertFalse(coordinator.isActive(jobA))
        XCTAssertFalse(coordinator.isQueued(jobA))
    }

    func testRebaseWaitsUntilTheRunEnds() {
        var coordinator = JobCoordinator()
        _ = coordinator.request(jobA, .scan, origin: .automatic, allowed: may)
        _ = coordinator.request(jobA, .files([file]), origin: .automatic, allowed: may)
        _ = coordinator.request(jobB, .scan, origin: .automatic, allowed: may)
        coordinator.rearmWhenIdle(jobA)
        // The run ends: re-arm first (it adopts the moved folder while nothing runs), nothing started yet.
        XCTAssertEqual(coordinator.finished(jobA, allowed: may), [.rearm(jobA)])
        XCTAssertTrue(coordinator.active.isEmpty)
        XCTAssertEqual(coordinator.startReady(allowed: may), [.start(jobA, .files([file]), .automatic)])
    }

    // MARK: Notifications

    func testNoticesAreCoalescedPerJobPerMinute() {
        var notices = JobNoticeCoalescer()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(notices.add(jobA, name: "Inbox", counts: .init(written: 0, failed: 0), now: start))
        XCTAssertEqual(notices.add(jobA, name: "Inbox", counts: .init(written: 2, failed: 0), now: start),
                       .init(title: "Job Inbox", body: RunCountsText.make(written: 2, skipped: 0, failed: 0)))
        XCTAssertNil(notices.add(jobA, name: "Inbox", counts: .init(written: 3, failed: 1),
                                 now: start.addingTimeInterval(10)))
        XCTAssertNil(notices.add(jobA, name: "Inbox", counts: .init(written: 1, failed: 0),
                                 now: start.addingTimeInterval(20)))
        XCTAssertEqual(notices.flushDate(for: jobA), start.addingTimeInterval(60))
        // Another job isn't held back.
        XCTAssertNotNil(notices.add(jobB, name: "Scans", counts: .init(written: 1, failed: 0),
                                    now: start.addingTimeInterval(20)))
        let summary = notices.flush(jobA, now: start.addingTimeInterval(60))
        XCTAssertEqual(summary?.body, RunCountsText.make(written: 4, skipped: 0, failed: 1) + " in 2 runs")
        XCTAssertNil(notices.flushDate(for: jobA))
    }

    func testAProblemIsNamed() {
        var notices = JobNoticeCoalescer()
        let notice = notices.add(jobA, name: "Inbox", counts: .init(written: 0, problem: "Folder gone."),
                                 now: Date())
        XCTAssertEqual(notice, .init(title: "Job Inbox had a problem", body: "Folder gone."))
    }

    // MARK: Editing

    func testEditorChangesAreMergedOntoTheCurrentJob() {
        let base = Job(name: "Inbox", inputs: [URL(fileURLWithPath: "/a/In")], output: .overwrite,
                       inputBookmarks: [Data("old".utf8)])
        var current = base
        current.inputs = [URL(fileURLWithPath: "/b/Moved")]
        current.inputBookmarks = [Data("moved".utf8)]
        var edited = base
        edited.name = "Inbox 2"
        edited.report = .csv
        let merged = Job.merge(base: base, edited: edited, current: current)
        XCTAssertEqual(merged.name, "Inbox 2")
        XCTAssertEqual(merged.report, .csv)
        XCTAssertEqual(merged.inputs, current.inputs)
        XCTAssertEqual(merged.inputBookmarks, current.inputBookmarks)

        edited.inputs.append(URL(fileURLWithPath: "/c/More"))
        let withFolders = Job.merge(base: base, edited: edited, current: current)
        XCTAssertEqual(withFolders.inputs, edited.inputs)
        XCTAssertNil(withFolders.inputBookmarks)
    }
}
