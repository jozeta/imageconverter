import XCTest
@testable import ImageconverterCore

final class URLActionTests: XCTestCase {
    private let readable: Set<String> = ["/Users/me/a.jpg", "/Users/me/Trip", "/Users/me/b c.png"]

    private func parse(_ string: String) -> URLAction? {
        guard let url = URL(string: string) else { return nil }
        return URLAction.parse(url) { self.readable.contains($0.path) }
    }

    func testOpen() {
        XCTAssertEqual(parse("imageconverter://open"), .open)
        XCTAssertEqual(parse("IMAGECONVERTER://OPEN/"), .open)
        XCTAssertFalse(URLAction.open.needsConfirmation)
    }

    func testOpenRejectsParametersAndPaths() {
        XCTAssertNil(parse("imageconverter://open?name=x"))
        XCTAssertNil(parse("imageconverter://open/extra"))
    }

    func testPreset() {
        XCTAssertEqual(parse("imageconverter://preset?name=Web%20export"), .selectPreset(name: "Web export"))
        XCTAssertEqual(parse("imageconverter://preset?name=%20%20Mine%20"), .selectPreset(name: "Mine"))
        XCTAssertTrue(URLAction.selectPreset(name: "x").needsConfirmation)
    }

    func testPresetRejectsBadNames() {
        XCTAssertNil(parse("imageconverter://preset"))
        XCTAssertNil(parse("imageconverter://preset?name="))
        XCTAssertNil(parse("imageconverter://preset?name=%20%20"))
        XCTAssertNil(parse("imageconverter://preset?name=a%0Ab"))
        XCTAssertNil(parse("imageconverter://preset?name=a&name=b"))
        XCTAssertNil(parse("imageconverter://preset?name=a&other=b"))
        XCTAssertNil(parse("imageconverter://preset?name=" + String(repeating: "x", count: 81)))
        XCTAssertNotNil(parse("imageconverter://preset?name=" + String(repeating: "x", count: 80)))
    }

    func testRunJob() {
        XCTAssertEqual(parse("imageconverter://jobs/run?name=Nightly"), .runJob(name: "Nightly"))
        XCTAssertTrue(URLAction.runJob(name: "x").needsConfirmation)
        XCTAssertNil(parse("imageconverter://jobs?name=Nightly"))
        XCTAssertNil(parse("imageconverter://jobs/delete?name=Nightly"))
        XCTAssertNil(parse("imageconverter://jobs/run/?name=Nightly"))
        XCTAssertNil(parse("imageconverter://jobs/run?name=Nightly&now=1"))
    }

    func testAddFiles() {
        let action = parse("imageconverter://add?path=/Users/me/a.jpg&path=/Users/me/Trip&path=/Users/me/b%20c.png")
        XCTAssertEqual(action, .addFiles([URL(fileURLWithPath: "/Users/me/a.jpg"),
                                          URL(fileURLWithPath: "/Users/me/Trip"),
                                          URL(fileURLWithPath: "/Users/me/b c.png")]))
        XCTAssertEqual(action?.needsConfirmation, true)
    }

    func testAddDropsDuplicatesAndStandardisesPaths() {
        XCTAssertEqual(parse("imageconverter://add?path=/Users/me/a.jpg&path=/Users/me/./x/../a.jpg"),
                       .addFiles([URL(fileURLWithPath: "/Users/me/a.jpg")]))
    }

    func testAddRejectsMissingRelativeAndOddPaths() {
        XCTAssertNil(parse("imageconverter://add"))
        XCTAssertNil(parse("imageconverter://add?path=/Users/me/missing.jpg"))
        // One bad path rejects the whole link.
        XCTAssertNil(parse("imageconverter://add?path=/Users/me/a.jpg&path=/etc/nothing"))
        XCTAssertNil(parse("imageconverter://add?path=a.jpg"))
        XCTAssertNil(parse("imageconverter://add?path=~/a.jpg"))
        XCTAssertNil(parse("imageconverter://add?path=/Users/me/a.jpg%00.png"))
        XCTAssertNil(parse("imageconverter://add?path=/Users/me/a.jpg&name=x"))
        XCTAssertNil(parse("imageconverter://add?file=/Users/me/a.jpg"))
    }

    func testAddCapsCountAndLength() {
        let many = Array(repeating: "path=/Users/me/a.jpg", count: URLAction.maxPaths + 1).joined(separator: "&")
        XCTAssertNil(parse("imageconverter://add?" + many))
        let long = "/" + String(repeating: "x", count: URLAction.maxPathLength)
        XCTAssertNil(parse("imageconverter://add?path=" + long))
    }

    func testRejectsUnknownHostsSchemesAndURLParts() {
        XCTAssertNil(parse("imageconverter://delete?path=/Users/me/a.jpg"))
        XCTAssertNil(parse("imageconverter://convert"))
        XCTAssertNil(parse("imageconverter:open"))
        XCTAssertNil(parse("imageconverter:///open"))
        XCTAssertNil(parse("https://open"))
        XCTAssertNil(parse("imageconverter://user:pw@open"))
        XCTAssertNil(parse("imageconverter://open:80"))
        XCTAssertNil(parse("imageconverter://open#frag"))
        XCTAssertNil(parse("imageconverter://preset?name"))
    }

    func testRejectsOverlongURLs() {
        let name = String(repeating: "x", count: URLAction.maxURLLength)
        XCTAssertNil(parse("imageconverter://preset?name=" + name))
    }

    func testDefaultReadableCheckUsesTheFileSystem() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("urlaction-\(UUID().uuidString).jpg")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var components = URLComponents(string: "imageconverter://add")
        components?.queryItems = [URLQueryItem(name: "path", value: file.path)]
        let url = try XCTUnwrap(components?.url)
        XCTAssertEqual(URLAction.parse(url), .addFiles([file.standardizedFileURL]))
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(URLAction.parse(url))
    }

    func testPercentEncodedPartsDecodeToKnownValuesOnly() {
        // Encoded host, path and parameter names mean the same as written out; nothing else becomes valid.
        XCTAssertEqual(parse("imageconverter://op%65n"), .open)
        XCTAssertEqual(parse("imageconverter://jobs/%72un?name=Nightly"), .runJob(name: "Nightly"))
        XCTAssertEqual(parse("imageconverter://preset?na%6De=Mine"), .selectPreset(name: "Mine"))
        XCTAssertEqual(parse("imageconverter://add?p%61th=%2FUsers%2Fme%2Fa.jpg"),
                       .addFiles([URL(fileURLWithPath: "/Users/me/a.jpg")]))
        XCTAssertNil(parse("imageconverter://de%6Cete"))
        XCTAssertNil(parse("imageconverter://jobs/%72un%2F?name=Nightly"))
        XCTAssertNil(parse("imageconverter://preset?na%6De=Mine&n%61me=Other"))
        XCTAssertNil(parse("imageconverter://add?path=%2FUsers%2Fme%2F..%2Fme%2Fmissing.jpg"))
    }

    func testFormatAndInvisibleCharactersInNamesAreRejected() {
        XCTAssertNil(parse("imageconverter://preset?name=Web%E2%80%AEtropxe"))   // right-to-left override
        XCTAssertNil(parse("imageconverter://preset?name=Web%E2%80%8Bexport"))   // zero-width space
        XCTAssertNil(parse("imageconverter://preset?name=Web%C2%ADexport"))      // soft hyphen
        XCTAssertNil(parse("imageconverter://jobs/run?name=Nightly%EF%BB%BF"))   // byte order mark
        XCTAssertNil(parse("imageconverter://preset?name=Web%00"))
        XCTAssertNil(parse("imageconverter://add?path=/Users/me/a.jpg%E2%80%AE"))
        XCTAssertEqual(parse("imageconverter://preset?name=Caf%C3%A9"), .selectPreset(name: "Café"))
    }
}
