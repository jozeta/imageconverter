import XCTest
@testable import ImageconverterCore

final class WorkWindowTests: XCTestCase {
    func testWindowLimitsItems() {
        var window = WorkWindow(maxItems: 2, maxWeight: 1_000)
        window.start(weight: 1)
        XCTAssertTrue(window.canStart(weight: 1))
        window.start(weight: 1)
        XCTAssertFalse(window.canStart(weight: 1))
    }

    func testWindowLimitsWeight() {
        var window = WorkWindow(maxItems: 10, maxWeight: 100)
        window.start(weight: 60)
        XCTAssertFalse(window.canStart(weight: 50))
        XCTAssertTrue(window.canStart(weight: 40))
    }

    func testOversizedItemRunsAlone() {
        var window = WorkWindow(maxItems: 10, maxWeight: 100)
        XCTAssertTrue(window.canStart(weight: 1_000))
        window.start(weight: 1_000)
        XCTAssertFalse(window.canStart(weight: 1))
    }

    func testFinishFreesWeight() {
        var window = WorkWindow(maxItems: 10, maxWeight: 100)
        window.start(weight: 60)
        window.finish(weight: 60)
        XCTAssertTrue(window.canStart(weight: 100))
        window.start(weight: 100)
        XCTAssertFalse(window.canStart(weight: 1))
    }
}

final class WorkWindowClampTests: XCTestCase {
    func testMaxItemsClampedToOne() {
        var window = WorkWindow(maxItems: 0, maxWeight: 10)
        XCTAssertEqual(window.maxItems, 1)
        XCTAssertTrue(window.canStart(weight: 1))
        window.start(weight: 1)
        XCTAssertFalse(window.canStart(weight: 1))
    }
}
