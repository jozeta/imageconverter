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

    /// Final review M4: two steps with the same path but different bookmarks; the one that opens wins, whichever
    /// comes first.
    func testWatermarkStepsSharingAPathUseTheBookmarkThatOpens() throws {
        let original = try logo()
        let withBookmark = ImageWatermark.chosen(original)
        let moved = root.appendingPathComponent("moved.png")
        try FileManager.default.moveItem(at: original, to: moved)
        let step = { (watermark: ImageWatermark) in
            PipelineStep(operation: .watermark(WatermarkOptions(content: .image(watermark))))
        }
        // An old step without a bookmark (its path is gone) comes first.
        let both = Pipeline(steps: [step(ImageWatermark(path: original.path)), step(withBookmark)])
        let assets = WatermarkAssets.load(for: both, maxPixels: 1_000_000)
        XCTAssertNotNil(assets.image(for: original.path))
        XCTAssertNil(assets.missingError(for: both))

        // The batch's asset pipeline keeps both variants (deduplicated by path and bookmark, not path only).
        let conditional = Pipeline(steps: [PipelineStep(operation: .condition(ConditionalStep()))])
        let resolved = ResolvedPipeline(pipeline: Pipeline(steps: both.steps + [step(withBookmark)]))
        XCTAssertEqual(BatchRunner.assetPipeline(conditional, resolved: [resolved]).steps.count, 2)
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

/// Fix round 1: access only counts when it really started; untrusted bookmarks never mount anything.
final class AccessScopeTests: XCTestCase {
    func testJournalCountsOnlyScopedBookmarksInTheRealSandbox() {
        let out = URL(fileURLWithPath: "/Out", isDirectory: true)
        var journal = RunJournal(items: [InputItem(source: URL(fileURLWithPath: "/P/a.png"), relativeDirectory: "")],
                                 pipeline: Pipeline(), mode: .newFolder(out), bookmarker: { _ in Data("b".utf8) })
        journal.completed = []
        let plain: (Data) -> FolderAccess.Resolved? = { _ in
            FolderAccess.Resolved(url: URL(fileURLWithPath: "/P", isDirectory: true), isSecurityScoped: false)
        }
        let sandboxed = journal.regainAccess(resolver: plain, enforced: true)
        XCTAssertTrue(sandboxed.access.isEmpty)
        XCTAssertEqual(sandboxed.unavailable.map(\.path), ["/P", "/Out"])
        let unsandboxed = journal.regainAccess(resolver: plain, enforced: false)
        XCTAssertEqual(unsandboxed.access.count, 2)
    }

    func testUntrustedBookmarksResolveWithoutMountingOrUI() {
        XCTAssertTrue(FolderAccess.resolveOptions.contains(.withoutMounting))
        XCTAssertTrue(FolderAccess.resolveOptions.contains(.withoutUI))
        XCTAssertNil(FolderAccess.resolve(Data(count: FolderAccess.maxBookmarkSize + 1)))
        XCTAssertNil(FolderAccess.resolveFile(Data("garbage".utf8)))
        XCTAssertNil(FolderAccess.resolveFile(Data()))
    }

    func testPlainURLsGiveAccessOutsideTheSandbox() {
        // (Outside the sandbox `startAccessingSecurityScopedResource` may even return true for a plain URL.)
        let grant = FolderAccess.Grant([URL(fileURLWithPath: "/tmp", isDirectory: true)])
        XCTAssertTrue(grant.givesAccess)
        grant.release()
    }

    func testStaleWatermarkBookmarksAreRenewedEverywhereInThePipeline() {
        let old = ImageWatermark(path: "/a/logo.png", bookmark: Data("old".utf8))
        let moved: (Data) -> FolderAccess.Resolved? = { _ in
            FolderAccess.Resolved(url: URL(fileURLWithPath: "/b/logo.png"), refreshed: Data("new".utf8))
        }
        let renewed = old.refreshed(resolver: moved)
        XCTAssertEqual(renewed?.bookmark, Data("new".utf8))
        XCTAssertEqual(renewed?.path, "/b/logo.png")
        XCTAssertNil(old.refreshed(resolver: { _ in FolderAccess.Resolved(url: URL(fileURLWithPath: "/a/logo.png")) }))

        let step = PipelineStep(operation: .watermark(WatermarkOptions(content: .image(old))))
        let condition = ConditionalStep(then: [.step(step)], otherwise: [.step(step)])
        let pipeline = Pipeline(steps: [step, PipelineStep(operation: .condition(condition))])
        let updated = pipeline.updatingImageWatermarks { $0.refreshed(resolver: moved) }
        var bookmarks: [Data?] = []
        _ = updated?.updatingImageWatermarks { bookmarks.append($0.bookmark); return nil }
        XCTAssertEqual(bookmarks, Array(repeating: Data("new".utf8), count: 3))
        XCTAssertNil(pipeline.updatingImageWatermarks { _ in nil })
    }
}
