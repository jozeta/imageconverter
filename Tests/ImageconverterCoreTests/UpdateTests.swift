import XCTest
@testable import ImageconverterCore

final class UpdateTests: XCTestCase {
    private let current = AppVersion("1.1.0")!
    private let host = "https://github.com/jozeta/imageconverter/releases/download"

    private func json(tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false, body: String = "Notes",
                      zipName: String = "imageconverter-1.2.0.zip", shaName: String = "imageconverter-1.2.0.zip.sha256",
                      zipURL: String? = nil, shaURL: String? = nil, zipSize: Int = 1000, shaSize: Int = 90) -> Data {
        let object: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "body": body,
            "assets": [
                ["name": zipName, "browser_download_url": zipURL ?? "\(host)/\(tag)/\(zipName)", "size": zipSize],
                ["name": shaName, "browser_download_url": shaURL ?? "\(host)/\(tag)/\(shaName)", "size": shaSize]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func v(_ version: String) -> Data {
        json(tag: "v\(version)", zipName: "imageconverter-\(version).zip", shaName: "imageconverter-\(version).zip.sha256")
    }

    private func assertThrows(_ data: Data, _ expected: UpdateError? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try UpdateRelease.parse(data, current: current), file: file, line: line) { error in
            if let expected { XCTAssertEqual(error as? UpdateError, expected, file: file, line: line) }
        }
    }

    func testVersionParsingIsStrict() {
        XCTAssertEqual(AppVersion("1.10.0"), AppVersion(major: 1, minor: 10, patch: 0))
        for bad in ["1.2", "1.2.3.4", "01.2.0", "1.02.0", "1.2.03",
                    "v1.2.0", "1.2.x", "-1.2.0",
                    "+1.2.0", "1..0", "", "1.2.0-beta", " 1.2.0", "1.2.0\n", "1.2.9999999"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
        XCTAssertNotNil(AppVersion("0.0.0"))
    }

    func testVersionOrdering() {
        XCTAssertGreaterThan(AppVersion("1.10.0")!, AppVersion("1.9.0")!)
        XCTAssertGreaterThan(AppVersion("2.0.0")!, AppVersion("1.99.99")!)
        XCTAssertLessThan(AppVersion("1.2.3")!, AppVersion("1.2.4")!)
        XCTAssertEqual(AppVersion("1.2.3")!.description, "1.2.3")
    }

    func testParsesValidRelease() throws {
        let release = try XCTUnwrap(UpdateRelease.parse(json(), current: current))
        XCTAssertEqual(release.version, AppVersion("1.2.0"))
        XCTAssertEqual(release.notes, "Notes")
        XCTAssertEqual(release.zipURL.host, "github.com")
        XCTAssertTrue(release.shaURL.lastPathComponent.hasSuffix(".sha256"))
    }

    func testSameOrOlderVersionIsUpToDate() throws {
        XCTAssertNil(try UpdateRelease.parse(v("1.1.0"), current: current))
        XCTAssertNil(try UpdateRelease.parse(v("1.0.0"), current: current))
    }

    func testRejectsBadTags() {
        for tag in ["v1.2", "v01.2.0", "1.2.0", "V1.2.0", "v1.2.0-beta", "vv1.2.0", ""] {
            assertThrows(json(tag: tag), .noSuitableRelease)
        }
    }

    func testRejectsDraftAndPrerelease() {
        assertThrows(json(draft: true), .noSuitableRelease)
        assertThrows(json(prerelease: true), .noSuitableRelease)
    }

    func testRejectsWrongAssetNames() {
        assertThrows(json(zipName: "imageconverter-1.2.1.zip"), .noSuitableRelease)
        assertThrows(json(shaName: "imageconverter-1.2.0.sha256"), .noSuitableRelease)
        assertThrows(json(zipName: "Imageconverter-1.2.0.zip"), .noSuitableRelease)
    }

    func testRejectsMissingAssetsAndBadJSON() {
        assertThrows(Data(#"{"tag_name":"v1.2.0"}"#.utf8), .noSuitableRelease)
        assertThrows(Data("not json".utf8), .invalidResponse)
        assertThrows(Data(), .invalidResponse)
        assertThrows(Data(#"{"tag_name":5}"#.utf8), .invalidResponse)
        assertThrows(Data(#"[1,2]"#.utf8), .invalidResponse)
    }

    func testRejectsHugeBody() {
        assertThrows(Data(repeating: 0x20, count: UpdatePolicy.maxResponseBytes + 1), .responseTooLarge)
    }

    func testRejectsBadURLs() {
        assertThrows(json(zipURL: "http://github.com/a/imageconverter-1.2.0.zip"), .disallowedURL)
        assertThrows(json(zipURL: "https://evil.example.com/imageconverter-1.2.0.zip"), .disallowedURL)
        assertThrows(json(shaURL: "https://github.com.evil.example/x.sha256"), .disallowedURL)
        assertThrows(json(zipURL: "https://user@github.com/x.zip"), .disallowedURL)
        assertThrows(json(zipURL: "https://github.com:8443/x.zip"), .disallowedURL)
        assertThrows(json(zipURL: "file:///etc/passwd"), .disallowedURL)
        assertThrows(json(zipURL: "not a url"), .disallowedURL)
    }

    func testAllowedHosts() {
        XCTAssertTrue(UpdatePolicy.allowedHost(URL(string: "https://github.com/a/b")!))
        XCTAssertTrue(UpdatePolicy.allowedHost(URL(string: "https://objects.githubusercontent.com/x")!))
        XCTAssertTrue(UpdatePolicy.allowedHost(URL(string: "https://release-assets.githubusercontent.com/x")!))
        XCTAssertFalse(UpdatePolicy.allowedHost(URL(string: "https://api.github.com/x")!))
        XCTAssertFalse(UpdatePolicy.allowedHost(URL(string: "http://objects.githubusercontent.com/x")!))
    }

    func testSizeCaps() {
        assertThrows(json(zipSize: UpdatePolicy.maxZipBytes + 1), .downloadTooLarge)
        assertThrows(json(shaSize: 1025), .downloadTooLarge)
        assertThrows(json(zipSize: 0), .downloadTooLarge)
        XCTAssertNotNil(try UpdateRelease.parse(json(zipSize: UpdatePolicy.maxZipBytes, shaSize: 1024), current: current))
    }

    func testNotesAreCapped() throws {
        let release = try XCTUnwrap(UpdateRelease.parse(json(body: String(repeating: "a", count: 30_000)), current: current))
        XCTAssertEqual(release.notes.count, UpdatePolicy.maxNotesCharacters)
    }

    func testChecksumParsing() {
        let hex = String(repeating: "ab", count: 32)
        let name = "imageconverter-1.2.0.zip"
        XCTAssertEqual(UpdatePolicy.expectedSHA256(from: Data("\(hex)  \(name)\n".utf8), fileName: name), hex)
        XCTAssertEqual(UpdatePolicy.expectedSHA256(from: Data("\(hex.uppercased())  \(name)".utf8), fileName: name), hex)
        XCTAssertNil(UpdatePolicy.expectedSHA256(from: Data("\(hex.dropLast())  \(name)".utf8), fileName: name))
        XCTAssertNil(UpdatePolicy.expectedSHA256(from: Data("\(hex)0  \(name)".utf8), fileName: name))
        XCTAssertNil(UpdatePolicy.expectedSHA256(from: Data("\(hex)  other.zip".utf8), fileName: name))
        let nonHex = String(repeating: "g", count: 64)
        XCTAssertNil(UpdatePolicy.expectedSHA256(from: Data("\(nonHex)  \(name)".utf8), fileName: name))
        XCTAssertNil(UpdatePolicy.expectedSHA256(from: Data("\(hex)  \(name)\n\(hex)  \(name)\n".utf8), fileName: name))
        XCTAssertNil(UpdatePolicy.expectedSHA256(from: Data(), fileName: name))
        XCTAssertNil(UpdatePolicy.expectedSHA256(from: Data(repeating: 0x61, count: 2000), fileName: name))
    }

    func testInstallPlanAndLaunchDecision() {
        XCTAssertEqual(UpdateInstallPlan.canInstall(isBundle: true, isRunning: false), .allowed)
        XCTAssertEqual(UpdateInstallPlan.canInstall(isBundle: false, isRunning: false),
                       .refused("Updates install only in the released app."))
        XCTAssertEqual(UpdateInstallPlan.canInstall(isBundle: true, isRunning: true), .refused("Finish the running batch or job first."))
        XCTAssertEqual(UpdateInstallPlan.shouldCheckOnLaunch(answer: nil), .ask)
        XCTAssertEqual(UpdateInstallPlan.shouldCheckOnLaunch(answer: true), .check)
        XCTAssertEqual(UpdateInstallPlan.shouldCheckOnLaunch(answer: false), .skip)
    }
}
