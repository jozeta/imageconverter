import XCTest
@testable import ImageconverterCore

final class AfterRunActionTests: XCTestCase {
    private func files(_ count: Int, folders: Int = 1) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/out/f\($0 % folders)/img\($0).jpg") }
    }

    func testNothingDoesNothing() {
        let plan = AfterRunAction.nothing.plan(written: files(3), appIsActive: false)
        XCTAssertTrue(plan.reveal.isEmpty)
        XCTAssertFalse(plan.notify)
    }

    func testRevealSelectsTheFiles() {
        let written = files(3)
        let plan = AfterRunAction.reveal.plan(written: written, appIsActive: true)
        XCTAssertEqual(plan.reveal, written)
        XCTAssertFalse(plan.notify)
    }

    func testRevealUsesFoldersAboveFiftyFiles() {
        let at50 = AfterRunAction.reveal.plan(written: files(50, folders: 3), appIsActive: true)
        XCTAssertEqual(at50.reveal.count, 50)
        let written = files(51, folders: 3)
        let plan = AfterRunAction.reveal.plan(written: written, appIsActive: true)
        XCTAssertEqual(plan.reveal.map(\.path), ["/out/f0", "/out/f1", "/out/f2"])
    }

    func testNotifyOnlyWhenAppIsInBackground() {
        XCTAssertTrue(AfterRunAction.notify.plan(written: files(2), appIsActive: false).notify)
        XCTAssertFalse(AfterRunAction.notify.plan(written: files(2), appIsActive: true).notify)
        XCTAssertTrue(AfterRunAction.notify.plan(written: files(2), appIsActive: false).reveal.isEmpty)
    }

    func testRevealAndNotifyDoesBoth() {
        let background = AfterRunAction.revealAndNotify.plan(written: files(2), appIsActive: false)
        XCTAssertEqual(background.reveal.count, 2)
        XCTAssertTrue(background.notify)
        let front = AfterRunAction.revealAndNotify.plan(written: files(2), appIsActive: true)
        XCTAssertEqual(front.reveal.count, 2)
        XCTAssertFalse(front.notify)
    }

    func testAllFailedNotifiesInBackgroundOnly() {
        XCTAssertTrue(AfterRunAction.notify.plan(written: [], failed: 3, appIsActive: false).notify)
        XCTAssertFalse(AfterRunAction.notify.plan(written: [], failed: 3, appIsActive: true).notify)
        XCTAssertFalse(AfterRunAction.nothing.plan(written: [], failed: 3, appIsActive: false).notify)
        XCTAssertTrue(AfterRunAction.revealAndNotify.plan(written: [], failed: 3, appIsActive: false).reveal.isEmpty)
    }

    func testNothingWrittenDoesNothing() {
        let plan = AfterRunAction.revealAndNotify.plan(written: [], appIsActive: false)
        XCTAssertTrue(plan.reveal.isEmpty)
        XCTAssertFalse(plan.notify)
    }
}
