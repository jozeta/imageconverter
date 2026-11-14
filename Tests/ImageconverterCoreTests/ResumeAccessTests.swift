import XCTest
@testable import ImageconverterCore

/// Final review I2: resuming in the sandbox never drops loose files silently. The journal bookmarks loose source
/// files (their folders can't be bookmarked), resuming asks for the folders of anything still unreadable, and what
/// stays unreadable after a Cancel is reported as "couldn't open", not as missing.
final class ResumeAccessTests: XCTestCase {
    private let out = URL(fileURLWithPath: "/Out", isDirectory: true)

    private func item(_ path: String) -> InputItem {
        InputItem(source: URL(fileURLWithPath: path), relativeDirectory: "")
    }

    // MARK: Journal

    func testLooseFilesGetTheirOwnBookmarksWhenTheirFolderHasNone() {
        // The app may read /Photos (a dropped folder) but not /Desktop, where two loose files were dropped from.
        let items = [item("/Photos/a.jpg"), item("/Photos/2026/b.jpg"), item("/Desktop/c.jpg"), item("/Desktop/d.jpg")]
        let journal = RunJournal(items: items, pipeline: Pipeline(), mode: .newFolder(out), bookmarker: { url in
            url.path.hasPrefix("/Desktop") && url.path.hasSuffix("Desktop") ? nil : Data(url.path.utf8)
        })
        XCTAssertEqual(journal.folderBookmarks?.map(\.path), ["/Photos"])
        XCTAssertEqual(journal.fileBookmarks?.map(\.path), ["/Desktop/c.jpg", "/Desktop/d.jpg"])
    }

    func testNoFileBookmarksWhenEveryFolderHasOne() {
        let journal = RunJournal(items: [item("/Photos/a.jpg")], pipeline: Pipeline(), mode: .newFolder(out),
                                 bookmarker: { Data($0.path.utf8) })
        XCTAssertNil(journal.fileBookmarks)
    }

    func testFileBookmarksAreCapped() {
        let items = (0..<(RunJournal.maxFileBookmarks + 5)).map { item("/Desktop/\($0).jpg") }
        let journal = RunJournal(items: items, pipeline: Pipeline(), mode: .newFolder(out), bookmarker: { url in
            url.pathExtension == "jpg" ? Data("b".utf8) : nil
        })
        XCTAssertEqual(journal.fileBookmarks?.count, RunJournal.maxFileBookmarks)
    }

    func testFileBookmarksRoundTripAndRegainOnlyScopedOnesInTheSandbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var journal = RunJournal(items: [item("/Desktop/c.jpg")], pipeline: Pipeline(), mode: .newFolder(out),
                                 bookmarker: { $0.pathExtension == "jpg" ? Data("file".utf8) : nil })
        journal.completed = []
        let url = root.appendingPathComponent("journal.json")
        try journal.write(to: url)
        let read = try XCTUnwrap(RunJournal.pending(at: url))
        XCTAssertEqual(read.fileBookmarks, journal.fileBookmarks)

        let file = URL(fileURLWithPath: "/Desktop/c.jpg")
        let scoped: (Data) -> FolderAccess.Resolved? = { _ in FolderAccess.Resolved(url: file, isSecurityScoped: true) }
        let plain: (Data) -> FolderAccess.Resolved? = { _ in FolderAccess.Resolved(url: file, isSecurityScoped: false) }
        XCTAssertEqual(read.regainFileAccess(resolver: scoped, enforced: true), [file])
        XCTAssertEqual(read.regainFileAccess(resolver: plain, enforced: true), [])
        XCTAssertEqual(read.regainFileAccess(resolver: plain, enforced: false), [file])
        XCTAssertEqual(read.regainFileAccess(resolver: { _ in nil }, enforced: true), [])
    }

    func testTooManyFileBookmarksMakeTheJournalInvalid() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var journal = RunJournal(items: [item("/Desktop/c.jpg")], pipeline: Pipeline(), mode: .newFolder(out),
                                 bookmarker: { _ in nil })
        journal.fileBookmarks = (0...RunJournal.maxFileBookmarks).map {
            RunJournal.FolderBookmark(path: "/Desktop/\($0).jpg", bookmark: Data("b".utf8))
        }
        let url = root.appendingPathComponent("journal.json")
        try journal.write(to: url)
        XCTAssertNil(RunJournal.pending(at: url))
    }

    // MARK: Asking before the plan

    func testAsksOnlyForTheFoldersOfUnreadableSourcesNotCovered() {
        let unreadable = [URL(fileURLWithPath: "/Desktop/c.jpg"), URL(fileURLWithPath: "/Desktop/d.jpg"),
                          URL(fileURLWithPath: "/Granted/e.jpg"), URL(fileURLWithPath: "/Other/f.jpg")]
        var asked: [String] = []
        var accepted: [String] = []
        let refused = AccessPrompt.askToRead(unreadable, covered: [URL(fileURLWithPath: "/Granted", isDirectory: true)],
                                             caseSensitive: true,
                                             ask: { need, _ in
                                                 XCTAssertEqual(need.purpose, .readOriginals)
                                                 asked.append(need.folder.path)
                                                 return need.folder
                                             },
                                             accept: { accepted.append($0.path) })
        XCTAssertEqual(asked, ["/Desktop", "/Other"])
        XCTAssertEqual(accepted, ["/Desktop", "/Other"])
        XCTAssertEqual(refused, [])
    }

    func testCancelReturnsEveryFolderStillNotAllowed() {
        let unreadable = [URL(fileURLWithPath: "/A/1.jpg"), URL(fileURLWithPath: "/B/2.jpg")]
        var asked = 0
        let refused = AccessPrompt.askToRead(unreadable, covered: [], caseSensitive: true,
                                             ask: { _, _ in asked += 1; return nil }, accept: { _ in XCTFail("cancelled") })
        XCTAssertEqual(asked, 1, "the first Cancel stops the questions")
        XCTAssertEqual(refused.map(\.path), ["/A", "/B"])
    }

    func testNothingUnreadableAsksNothing() {
        XCTAssertEqual(AccessPrompt.askToRead([], covered: [], ask: { _, _ in XCTFail("asked"); return nil },
                                              accept: { _ in }), [])
    }

    // MARK: Plan

    func testUnreadableItemsInARefusedFolderCouldNotBeOpenedTheRestAreMissing() {
        var journal = RunJournal(items: [item("/A/1.jpg"), item("/A/2.jpg"), item("/B/3.jpg"), item("/C/4.jpg")],
                                 pipeline: Pipeline(), mode: .newFolder(out), bookmarker: { _ in nil })
        journal.completed = []
        let plan = ResumePlan.make(journal: journal, existing: [], isReadable: { $0 == "/C/4.jpg" },
                                   directoryExists: { _ in true },
                                   refusedFolders: [URL(fileURLWithPath: "/A", isDirectory: true)])
        XCTAssertEqual(plan.toRun.map(\.source.path), ["/C/4.jpg"])
        XCTAssertEqual(plan.unopened.map(\.path), ["/A/1.jpg", "/A/2.jpg"])
        XCTAssertEqual(plan.missing.map(\.path), ["/B/3.jpg"])
    }

    func testOnlyUnopenedItemsIsNothingLeftButStillReported() {
        var journal = RunJournal(items: [item("/A/1.jpg")], pipeline: Pipeline(), mode: .newFolder(out),
                                 bookmarker: { _ in nil })
        journal.completed = []
        let plan = ResumePlan.make(journal: journal, existing: [], isReadable: { _ in false },
                                   directoryExists: { _ in true },
                                   refusedFolders: [URL(fileURLWithPath: "/A", isDirectory: true)])
        XCTAssertEqual(plan.problem, .nothingLeft)
        XCTAssertEqual(plan.unopened.count, 1)
        XCTAssertEqual(plan.missing, [])
    }
}
