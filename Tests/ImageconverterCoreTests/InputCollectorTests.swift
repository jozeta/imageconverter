import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class InputCollectorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        // Resolve symlinks (/var -> /private/var) so expected URLs match the collector's.
        dir = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCollectsImagesFromFoldersAndFiles() throws {
        let fileManager = FileManager.default
        let trip = dir.appendingPathComponent("Trip", isDirectory: true)
        let day2 = trip.appendingPathComponent("day2", isDirectory: true)
        try fileManager.createDirectory(at: day2, withIntermediateDirectories: true)
        let image = TestImages.make(width: 4, height: 4)
        try TestImages.write(image, to: trip.appendingPathComponent("a.png"), type: .png)
        try TestImages.write(image, to: trip.appendingPathComponent(".hidden.png"), type: .png)
        try TestImages.write(image, to: day2.appendingPathComponent("b.jpg"), type: .jpeg)
        try Data("hi".utf8).write(to: trip.appendingPathComponent("notes.txt"))
        try Data().write(to: trip.appendingPathComponent(".DS_Store"))
        try Data().write(to: day2.appendingPathComponent("broken.jpg"))
        let loose = dir.appendingPathComponent("c.heic")
        try TestImages.write(image, to: loose, type: .heic)

        let items = InputCollector.collect([trip, loose, loose])

        XCTAssertEqual(items, [
            InputItem(source: trip.appendingPathComponent("a.png"), relativeDirectory: "Trip"),
            InputItem(source: day2.appendingPathComponent("b.jpg"), relativeDirectory: "Trip/day2"),
            InputItem(source: day2.appendingPathComponent("broken.jpg"), relativeDirectory: "Trip/day2"),
            InputItem(source: loose, relativeDirectory: "")
        ])
    }
}
