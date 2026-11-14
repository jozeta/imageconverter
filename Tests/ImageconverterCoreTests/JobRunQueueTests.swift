import XCTest
@testable import ImageconverterCore

final class JobRunQueueTests: XCTestCase {
    private let id = UUID()
    private let fileA = URL(fileURLWithPath: "/in/a.jpg")
    private let fileB = URL(fileURLWithPath: "/in/b.jpg")

    func testFirstRequestStartsAndLaterOnesWait() {
        var queue = JobRunQueue()
        XCTAssertEqual(queue.request(id, .files([fileA])), .files([fileA]))
        XCTAssertTrue(queue.isRunning(id))
        XCTAssertNil(queue.request(id, .files([fileB])))
        XCTAssertTrue(queue.hasPending(id))
    }

    func testTriggersDuringARunCoalesceIntoOneFollowUp() {
        var queue = JobRunQueue()
        _ = queue.request(id, .scan)
        XCTAssertNil(queue.request(id, .files([fileA])))
        XCTAssertNil(queue.request(id, .files([fileB])))
        XCTAssertEqual(queue.finish(id), .files([fileA, fileB]))
        // The follow-up runs: the job is still busy, and ends idle.
        XCTAssertTrue(queue.isRunning(id))
        XCTAssertNil(queue.finish(id))
        XCTAssertFalse(queue.isRunning(id))
        XCTAssertEqual(queue.request(id, .scan), .scan)
    }

    func testAScanCoversFiles() {
        XCTAssertEqual(JobRunRequest.files([fileA]).merged(with: .scan), .scan)
        XCTAssertEqual(JobRunRequest.scan.merged(with: .files([fileA])), .scan)
        XCTAssertEqual(JobRunRequest.files([fileB, fileA]).files, [fileA, fileB])
        XCTAssertNil(JobRunRequest.scan.files)
    }

    func testJobsAreIndependentAndPendingCanBeDropped() {
        var queue = JobRunQueue()
        let other = UUID()
        _ = queue.request(id, .scan)
        XCTAssertEqual(queue.request(other, .scan), .scan)
        XCTAssertNil(queue.request(id, .scan))
        queue.dropPending(id)
        XCTAssertNil(queue.finish(id))
        XCTAssertEqual(queue.runningIDs, [other])
    }
}
