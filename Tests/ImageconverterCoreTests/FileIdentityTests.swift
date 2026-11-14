import XCTest
@testable import ImageconverterCore

/// Re-review m2/m3: a file is one file however its path is spelled, and case only matters where the volume says so.
final class FileIdentityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The same original listed directly and through a symlinked folder is one item, and in overwrite mode the
    /// planner refuses the second plan.
    func testSymlinkedFolderIsTheSameFile() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("x.jpg")
        try TestImages.write(TestImages.make(width: 8, height: 8), to: file, type: .jpeg)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let direct = InputItem(source: file, relativeDirectory: "")
        let viaAlias = InputItem(source: alias.appendingPathComponent("x.jpg"), relativeDirectory: "alias")
        XCTAssertEqual(InputItem.unique([direct, viaAlias]), [direct])
        let plans = OutputPlanner.plan([direct, viaAlias], format: .jpeg, mode: .overwrite, fileExists: { _ in false })
        XCTAssertTrue(plans[1].isRefused)
        // A planned name in the aliased folder collides with the real one.
        XCTAssertEqual(FileIdentity.pathKey(alias.appendingPathComponent("new.jpg")),
                       FileIdentity.pathKey(real.appendingPathComponent("new.jpg")))
    }

    func testHardLinkIsTheSameFile() throws {
        let file = root.appendingPathComponent("a.jpg")
        try TestImages.write(TestImages.make(width: 8, height: 8), to: file, type: .jpeg)
        let link = root.appendingPathComponent("b.jpg")
        try FileManager.default.linkItem(at: file, to: link)
        XCTAssertEqual(FileIdentity.key(file), FileIdentity.key(link))
        XCTAssertEqual(InputItem.unique([InputItem(source: file, relativeDirectory: ""),
                                         InputItem(source: link, relativeDirectory: "")]).count, 1)
    }

    func testCaseFollowsTheVolume() {
        let upper = URL(fileURLWithPath: "/nowhere/Photos/A.jpg")
        let lower = URL(fileURLWithPath: "/nowhere/photos/a.jpg")
        XCTAssertEqual(FileIdentity.pathKey(upper, caseSensitive: false), FileIdentity.pathKey(lower, caseSensitive: false))
        XCTAssertNotEqual(FileIdentity.pathKey(upper, caseSensitive: true), FileIdentity.pathKey(lower, caseSensitive: true))
        // The lookup matches what the volume itself reports.
        let reported = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        XCTAssertEqual(FileIdentity.isCaseSensitive(root), reported)
        XCTAssertEqual(FileIdentity.isCaseSensitive(root.appendingPathComponent("missing/deeper")), reported)
    }

    /// Two different files that differ only in case are two items on a case-sensitive volume (their inodes differ).
    func testDistinctFilesStayDistinct() throws {
        let one = root.appendingPathComponent("one.jpg")
        let two = root.appendingPathComponent("two.jpg")
        for url in [one, two] { try TestImages.write(TestImages.make(width: 8, height: 8), to: url, type: .jpeg) }
        XCTAssertNotEqual(FileIdentity.key(one), FileIdentity.key(two))
    }
}
