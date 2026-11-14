import XCTest
@testable import ImageconverterCore

final class AccessNeedsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ path: String) -> URL { root.appendingPathComponent(path) }

    private func paths(_ urls: [URL]) -> [String] { urls.map { $0.standardizedFileURL.path } }

    func testSameFolderAsksForEachParentOnce() throws {
        let photos = try folder("Photos")
        let other = try folder("Other")
        let needed = AccessNeeds.foldersNeedingAccess(
            sources: [file("Photos/a.jpg"), file("Photos/b.jpg"), file("Other/c.jpg")],
            mode: .sameFolder(suffix: "_new"), covered: [])
        XCTAssertEqual(paths(needed), paths([other, photos]))
    }

    func testNestedFoldersAreAskedOnceThroughTheOuterOne() throws {
        let photos = try folder("Photos")
        _ = try folder("Photos/2026/May")
        let needed = AccessNeeds.foldersNeedingAccess(
            sources: [file("Photos/2026/May/a.jpg"), file("Photos/b.jpg")], mode: .overwrite, covered: [])
        XCTAssertEqual(paths(needed), paths([photos]))
        let purposes = AccessNeeds.needs(sources: [file("Photos/b.jpg")], mode: .overwrite, covered: []).map(\.purpose)
        XCTAssertEqual(purposes, [.replaceOriginals])
    }

    func testFolderCoveredByAGrantedAncestorIsNotAsked() throws {
        _ = try folder("Photos/2026")
        let other = try folder("Photosynthesis")
        let needed = AccessNeeds.foldersNeedingAccess(
            sources: [file("Photos/2026/a.jpg"), file("Photosynthesis/b.jpg")], mode: .sameFolder(suffix: "_x"),
            covered: [root.appendingPathComponent("Photos", isDirectory: true)])
        // Component-wise: "Photos" doesn't cover "Photosynthesis".
        XCTAssertEqual(paths(needed), paths([other]))
        XCTAssertTrue(AccessNeeds.foldersNeedingAccess(sources: [file("Photos/2026/a.jpg")], mode: .overwrite,
                                                       covered: [root]).isEmpty)
    }

    func testSymlinksAreResolvedOnBothSides() throws {
        let real = try folder("Real")
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(AccessNeeds.foldersNeedingAccess(sources: [link.appendingPathComponent("a.jpg")],
                                                       mode: .overwrite, covered: [real]).isEmpty)
        XCTAssertTrue(AccessNeeds.foldersNeedingAccess(sources: [real.appendingPathComponent("a.jpg")],
                                                       mode: .overwrite, covered: [link]).isEmpty)
        // The same folder through two spellings is asked once.
        let needed = AccessNeeds.foldersNeedingAccess(
            sources: [link.appendingPathComponent("a.jpg"), real.appendingPathComponent("b.jpg")],
            mode: .overwrite, covered: [])
        XCTAssertEqual(needed.count, 1)
    }

    func testCaseFollowsTheVolume() {
        let source = URL(fileURLWithPath: "/Volumes/Card/DCIM/a.jpg")
        let grant = URL(fileURLWithPath: "/Volumes/Card/dcim", isDirectory: true)
        XCTAssertTrue(AccessNeeds.foldersNeedingAccess(sources: [source], mode: .overwrite, covered: [grant],
                                                       caseSensitive: false).isEmpty)
        XCTAssertEqual(AccessNeeds.foldersNeedingAccess(sources: [source], mode: .overwrite, covered: [grant],
                                                        caseSensitive: true).map(\.path), ["/Volumes/Card/DCIM"])
        // Two spellings on a case-insensitive volume are one folder.
        XCTAssertEqual(AccessNeeds.foldersNeedingAccess(
            sources: [source, URL(fileURLWithPath: "/Volumes/Card/dcim/b.jpg")], mode: .overwrite, covered: [],
            caseSensitive: false).count, 1)
    }

    func testNewFolderNeedsOnlyTheOutputFolder() throws {
        let out = try folder("Out")
        let sources = [file("Photos/a.jpg")]
        XCTAssertEqual(paths(AccessNeeds.foldersNeedingAccess(sources: sources, mode: .newFolder(out), covered: [])),
                       paths([out]))
        XCTAssertTrue(AccessNeeds.foldersNeedingAccess(sources: sources, mode: .newFolder(out), covered: [root]).isEmpty)
        // A source that can't be read adds its folder, after the output folder's question.
        let needs = AccessNeeds.needs(sources: sources, mode: .newFolder(out), covered: [], isReadable: { _ in false })
        XCTAssertEqual(needs.map(\.purpose), [.saveToOutputFolder, .readOriginals])
    }

    func testRootsAndCoveringGrants() throws {
        let outer = try folder("A")
        let inner = try folder("A/B")
        let third = try folder("C")
        XCTAssertEqual(paths(AccessNeeds.roots(of: [inner, outer, third, outer])), paths([outer, third]))
        XCTAssertEqual(AccessNeeds.roots([third, outer, root.appendingPathComponent("D")], covering: [inner]), [1])
    }
}
