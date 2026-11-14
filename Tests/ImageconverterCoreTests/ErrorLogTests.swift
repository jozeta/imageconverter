import XCTest
@testable import ImageconverterCore

final class ErrorLogTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("errorlog-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testRecordAndRecentNewestFirst() {
        let log = ErrorLog.shared(directory: directory)
        log.record(path: "/in/a.jpg", reason: "Unreadable", at: Date(timeIntervalSince1970: 100))
        log.record(path: "/in/b\n.jpg", reason: "Line1\nLine2\u{2028}x", at: Date(timeIntervalSince1970: 200))
        let recent = log.recent(limit: 10)
        XCTAssertEqual(recent.map(\.path), ["/in/b?.jpg", "/in/a.jpg"])
        XCTAssertEqual(recent[0].reason, "Line1?Line2?x")
        XCTAssertEqual(recent[1].date, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(log.recent(limit: 1).count, 1)
        XCTAssertEqual(try String(contentsOf: log.logURL).components(separatedBy: "\n").count, 3)
    }

    func testErrorLogRotation() throws {
        let log = ErrorLog.shared(directory: directory, maxBytes: 300)
        for index in 0..<40 { log.record(path: "/in/\(index).jpg", reason: "boom", at: Date(timeIntervalSince1970: Double(index))) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["errors.1.log", "errors.2.log", "errors.3.log", "errors.log"])
        for name in names {
            let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? Int
            XCTAssertLessThanOrEqual(try XCTUnwrap(size), 300)
        }
        // The newest entry is first and reading continues into rotated files.
        let recent = ErrorLog.shared(directory: directory, maxBytes: 300).recent(limit: 100)
        XCTAssertEqual(recent.first?.path, "/in/39.jpg")
        XCTAssertGreaterThan(recent.count, 10)
        XCTAssertLessThan(recent.count, 40)
    }

    func testGarbageLinesAndSymlinkAreIgnored() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = ErrorLog.shared(directory: directory)
        try Data("not a line\n1970-01-01T00:00:10Z\t/in/x.jpg\tfine\n\n".utf8).write(to: log.logURL)
        XCTAssertEqual(log.recent(limit: 5).map(\.path), ["/in/x.jpg"])
        try FileManager.default.removeItem(at: log.logURL)
        try FileManager.default.createSymbolicLink(at: log.logURL, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertTrue(log.recent(limit: 5).isEmpty)
    }
}
