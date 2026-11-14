import XCTest
@testable import ImageconverterCore

/// Final review M9: a file drag that also offers text and lands on a step row adds the files.
final class DropPayloadTests: XCTestCase {
    func testFileURLsAndPathsAreFilesEverythingElseIsIgnored() {
        let strings = [
            "file:///Users/me/Photos/a%20b.jpg",
            "/Users/me/Photos/c.jpg\n/Users/me/Photos/../Photos/c.jpg\n  /tmp/folder  ",
            UUID().uuidString,
            "conditionAction:\(UUID().uuidString)",
            "https://example.com/x.jpg",
            "relative/path.jpg",
            "/bad\u{0}path",
            ""
        ]
        XCTAssertEqual(DropPayload.fileURLs(in: strings).map(\.path),
                       ["/Users/me/Photos/a b.jpg", "/Users/me/Photos/c.jpg", "/tmp/folder"])
    }

    func testAStepIDIsNoFile() {
        XCTAssertEqual(DropPayload.fileURLs(in: [UUID().uuidString]), [])
    }

    func testCapped() {
        let many = (0...DropPayload.maxFiles).map { "/f/\($0).jpg" }.joined(separator: "\n")
        XCTAssertEqual(DropPayload.fileURLs(in: [many]).count, DropPayload.maxFiles)
    }
}
