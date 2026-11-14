import XCTest
@testable import ImageconverterCore

/// Bookmarks for the watermark image and the run journal's folders (plain bookmarks: the tests aren't sandboxed).
final class AccessBookmarkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func logo(_ name: String = "logo.png") throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: 8, height: 8), to: url, type: .png)
        return url
    }

    private func pipeline(_ watermark: ImageWatermark) -> Pipeline {
        Pipeline(steps: [PipelineStep(operation: .watermark(WatermarkOptions(content: .image(watermark))))])
    }

    func testWatermarkBookmarkRoundTripsAndOldJSONStillDecodes() throws {
        let watermark = ImageWatermark.chosen(try logo())
        XCTAssertNotNil(watermark.bookmark)
        let decoded = try JSONDecoder().decode(ImageWatermark.self, from: JSONEncoder().encode(watermark))
        XCTAssertEqual(decoded, watermark)
        let old = try JSONDecoder().decode(ImageWatermark.self, from: Data(#"{"path":"/a/logo.png"}"#.utf8))
        XCTAssertEqual(old, ImageWatermark(path: "/a/logo.png"))
        // An oversized bookmark in an untrusted file is dropped, not trusted.
        let huge = Data(count: ImageWatermark.maxBookmarkSize + 1).base64EncodedString()
        let hostile = try JSONDecoder().decode(ImageWatermark.self,
                                               from: Data(#"{"path":"/a/logo.png","bookmark":"\#(huge)"}"#.utf8))
        XCTAssertNil(hostile.bookmark)
    }

    func testWatermarkFollowsTheBookmarkWhenTheFileMoved() throws {
        let original = try logo()
        let watermark = ImageWatermark.chosen(original)
        let moved = root.appendingPathComponent("moved.png")
        try FileManager.default.moveItem(at: original, to: moved)
        let opened = watermark.withFile { $0?.resolvingSymlinksInPath().path }
        XCTAssertEqual(opened, moved.path)
        let assets = WatermarkAssets.load(for: pipeline(watermark), maxPixels: 1_000_000)
        XCTAssertNotNil(assets.image(for: original.path))
    }

    func testUnresolvableBookmarkAsksToChooseTheImageAgain() throws {
        let original = try logo()
        let watermark = ImageWatermark.chosen(original)
        try FileManager.default.removeItem(at: original)
        XCTAssertNil(watermark.withFile { $0 })
        let assets = WatermarkAssets.load(for: pipeline(watermark), maxPixels: 1_000_000)
        XCTAssertEqual(assets.missingError(for: pipeline(watermark)), .watermarkImageNoAccess)
        XCTAssertEqual(ConversionError.watermarkImageNoAccess.reason,
                       "Couldn't open the watermark image \u{2014} choose it again")
        // Without a bookmark (older pipelines) a missing file is just unreadable.
        let plain = pipeline(ImageWatermark(path: original.path))
        XCTAssertEqual(WatermarkAssets.load(for: plain, maxPixels: 1_000_000).missingError(for: plain),
                       .watermarkImageUnreadable)
    }

    func testJournalKeepsBookmarksForSourceFoldersAndTheOutputFolder() throws {
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let nested = photos.appendingPathComponent("2026", isDirectory: true)
        let out = root.appendingPathComponent("Out", isDirectory: true)
        for folder in [nested, out] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let items = [InputItem(source: photos.appendingPathComponent("a.png"), relativeDirectory: ""),
                     InputItem(source: nested.appendingPathComponent("b.png"), relativeDirectory: "2026")]
        let journal = RunJournal(items: items, pipeline: Pipeline(), mode: .newFolder(out))
        // One bookmark for Photos (it contains 2026), one for the output folder.
        XCTAssertEqual(journal.folderBookmarks?.map(\.path), [photos.path])
        XCTAssertNotNil(journal.outputBookmark)

        let url = root.appendingPathComponent("journal.json")
        try journal.write(to: url)
        let read = try XCTUnwrap(RunJournal.pending(at: url))
        XCTAssertEqual(read.folderBookmarks, journal.folderBookmarks)
        XCTAssertEqual(read.outputBookmark, journal.outputBookmark)

        // Photos moved, Out deleted: access follows Photos, Out is reported by its path.
        let moved = root.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.moveItem(at: photos, to: moved)
        try FileManager.default.removeItem(at: out)
        let regained = read.regainAccess()
        XCTAssertEqual(regained.access.map { $0.resolvingSymlinksInPath().path }, [moved.path])
        XCTAssertEqual(regained.unavailable.map(\.path), [out.path])
    }

    func testOlderJournalWithoutBookmarksStillLoads() throws {
        let item = InputItem(source: root.appendingPathComponent("a.png"), relativeDirectory: "")
        var journal = RunJournal(items: [item], pipeline: Pipeline(), mode: .overwrite, bookmarker: { _ in nil })
        XCTAssertNil(journal.folderBookmarks)
        journal.completed = []
        let url = root.appendingPathComponent("journal.json")
        try journal.write(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("folderBookmarks"))
        let read = try XCTUnwrap(RunJournal.pending(at: url))
        XCTAssertTrue(read.regainAccess().access.isEmpty)
        XCTAssertTrue(read.regainAccess().unavailable.isEmpty)
    }
}
