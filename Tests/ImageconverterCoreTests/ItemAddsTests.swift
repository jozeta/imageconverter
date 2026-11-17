import XCTest
@testable import ImageconverterCore

final class ItemAddsTests: XCTestCase {
    private func items(_ count: Int, folder: String = "/tmp/adds") -> [InputItem] {
        (0..<count).map { InputItem(source: URL(fileURLWithPath: "\(folder)/\($0).jpg"), relativeDirectory: "") }
    }

    func testAddManyFilesIsOneUpdate() {
        var adds = ItemAdds()
        var updates = 0
        var list = items(3) { didSet { updates += 1 } }
        let token = adds.begin()
        XCTAssertTrue(adds.isAdding)
        // 5000 found, the first 3 already listed.
        let outcome = adds.finish(token, found: items(5000), existing: list, running: false)
        guard case .replace(let merged) = outcome else { return XCTFail("\(outcome)") }
        list = merged
        XCTAssertEqual(updates, 1, "One change to the list, not one per file")
        XCTAssertEqual(list.count, 5000)
        XCTAssertEqual(list.prefix(3).map(\.source), items(3).map(\.source), "Existing items stay first")
        XCTAssertFalse(adds.isAdding)
    }

    func testClearCancelsPendingAdd() {
        var adds = ItemAdds()
        let token = adds.begin()
        adds.clear()
        XCTAssertFalse(adds.isAdding, "Clear ends the add at once")
        XCTAssertEqual(adds.finish(token, found: items(10), existing: [], running: false), .dropped)
        XCTAssertFalse(adds.isAdding)
        // A new add after the Clear works as usual.
        let next = adds.begin()
        XCTAssertEqual(adds.finish(next, found: items(2), existing: [], running: false), .replace(items(2)))
    }

    func testAddDuringRunIsQueued() {
        var adds = ItemAdds()
        let token = adds.begin()
        XCTAssertEqual(adds.finish(token, found: items(4), existing: items(1), running: true), .queued(4))
        XCTAssertFalse(adds.isAdding)
        XCTAssertTrue(adds.hasQueued)
        // After the run: appended once, without the duplicate.
        let after = adds.takeQueued(existing: items(1))
        XCTAssertEqual(after, ItemAdds.Merge(items: items(4), added: 3))
        XCTAssertFalse(adds.hasQueued)
        XCTAssertNil(adds.takeQueued(existing: items(4)))
        // A Clear drops what waits for the run's end too.
        let again = adds.begin()
        _ = adds.finish(again, found: items(2, folder: "/tmp/other"), existing: [], running: true)
        adds.clear()
        XCTAssertNil(adds.takeQueued(existing: []))
    }
}
