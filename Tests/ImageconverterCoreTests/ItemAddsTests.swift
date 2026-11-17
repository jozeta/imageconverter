import XCTest
@testable import ImageconverterCore

final class ItemAddsTests: XCTestCase {
    private func items(_ count: Int, folder: String = "/tmp/adds") -> [InputItem] {
        (0..<count).map { InputItem(source: URL(fileURLWithPath: "\(folder)/\($0).jpg"), relativeDirectory: "") }
    }

    func testAddManyFilesIsOneUpdate() {
        var adds = ItemAdds()
        let existing = items(3)
        let token = adds.begin()
        XCTAssertTrue(adds.isAdding)
        // 5000 found, the first 3 already listed: one new list, existing first, no duplicates.
        let found = ItemAdds.prepare(items(5000), against: existing)
        XCTAssertEqual(found.new.count, 4997)
        guard case .replace(let merged) = adds.finish(token, found: found, existing: existing, running: false) else {
            return XCTFail("Expected one replacement")
        }
        XCTAssertEqual(merged.map(\.source), items(5000).map(\.source))
        XCTAssertFalse(adds.isAdding)
    }

    func testAddingListedFilesLeavesTheListAlone() {
        var adds = ItemAdds()
        let existing = items(4)
        let token = adds.begin()
        let found = ItemAdds.prepare(items(4), against: existing)
        XCTAssertEqual(adds.finish(token, found: found, existing: existing, running: false), .unchanged)
        XCTAssertFalse(adds.isAdding)
    }

    func testListChangedDuringScanIsMergedAgainstTheCurrentList() {
        var adds = ItemAdds()
        let token = adds.begin()
        let found = ItemAdds.prepare(items(3), against: [])
        // Another add listed item 0 meanwhile: it isn't added twice.
        let now = Array(items(1))
        XCTAssertEqual(adds.finish(token, found: found, existing: now, running: false), .replace(items(3)))
    }

    func testClearCancelsPendingAdd() {
        var adds = ItemAdds()
        let token = adds.begin()
        adds.clear()
        XCTAssertFalse(adds.isAdding, "Clear ends the add at once")
        let found = ItemAdds.prepare(items(10), against: [])
        XCTAssertEqual(adds.finish(token, found: found, existing: [], running: false), .dropped)
        XCTAssertFalse(adds.isAdding)
        // A new add after the Clear works as usual.
        let next = adds.begin()
        XCTAssertEqual(adds.finish(next, found: ItemAdds.prepare(items(2), against: []), existing: [], running: false),
                       .replace(items(2)))
    }

    func testAddDuringRunIsQueued() {
        var adds = ItemAdds()
        let token = adds.begin()
        let found = ItemAdds.prepare(items(4), against: items(1))
        XCTAssertEqual(adds.finish(token, found: found, existing: items(1), running: true), .queued(4))
        XCTAssertFalse(adds.isAdding)
        XCTAssertTrue(adds.hasQueued)
        // After the run: appended once, without the duplicate.
        XCTAssertEqual(adds.takeQueued(existing: items(1)), ItemAdds.Merge(items: items(4), added: 3))
        XCTAssertFalse(adds.hasQueued)
        XCTAssertNil(adds.takeQueued(existing: items(4)))
        // A Clear drops what waits for the run's end too.
        let again = adds.begin()
        _ = adds.finish(again, found: ItemAdds.prepare(items(2, folder: "/tmp/other"), against: []), existing: [],
                        running: true)
        adds.clear()
        XCTAssertNil(adds.takeQueued(existing: []))
    }
}
