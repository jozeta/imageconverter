import XCTest
@testable import ImageconverterCore

final class AccessPromptTests: XCTestCase {
    private let photos = URL(fileURLWithPath: "/Volumes/T/Photos", isDirectory: true)
    private let trip = URL(fileURLWithPath: "/Volumes/T/Photos/Trip", isDirectory: true)
    private let other = URL(fileURLWithPath: "/Volumes/T/Other", isDirectory: true)

    private func sources(_ folders: URL...) -> [URL] { folders.map { $0.appendingPathComponent("a.jpg") } }

    func testNothingAskedWhenCovered() {
        var asked = 0
        let outcome = AccessPrompt.run(sources: sources(photos, trip), mode: .overwrite, covered: [photos],
                                       caseSensitive: true, ask: { _, _ in asked += 1; return nil }, accept: { _ in })
        XCTAssertEqual(outcome, .granted)
        XCTAssertEqual(asked, 0)
    }

    func testAnAncestorAnswersSeveralFoldersAtOnce() {
        var questions: [URL] = []
        var accepted: [URL] = []
        let outcome = AccessPrompt.run(sources: sources(trip, other), mode: .sameFolder(suffix: "_x"), covered: [],
                                       caseSensitive: true,
                                       ask: { need, _ in questions.append(need.folder); return URL(fileURLWithPath: "/Volumes/T") },
                                       accept: { accepted.append($0) })
        XCTAssertEqual(outcome, .granted)
        XCTAssertEqual(questions.map(\.path), ["/Volumes/T/Other"])
        XCTAssertEqual(accepted.map(\.path), ["/Volumes/T"])
    }

    func testAnUnrelatedAnswerIsNotRememberedAndTheFolderIsAskedAgain() {
        var answers = [other, photos]
        var again: [Bool] = []
        var accepted: [URL] = []
        let outcome = AccessPrompt.run(sources: sources(photos), mode: .overwrite, covered: [], caseSensitive: true,
                                       ask: { _, isAgain in again.append(isAgain); return answers.removeFirst() },
                                       accept: { accepted.append($0) })
        XCTAssertEqual(outcome, .granted)
        XCTAssertEqual(again, [false, true])
        XCTAssertEqual(accepted, [photos])
    }

    func testCancelAndRepeatedWrongAnswersRefuse() {
        let need = AccessNeeds.Need(folder: photos, purpose: .replaceOriginals)
        XCTAssertEqual(AccessPrompt.run(sources: sources(photos), mode: .overwrite, covered: [], caseSensitive: true,
                                        ask: { _, _ in nil }, accept: { _ in XCTFail("nothing to accept") }),
                       .refused(need))
        var asked = 0
        XCTAssertEqual(AccessPrompt.run(sources: sources(photos), mode: .overwrite, covered: [], caseSensitive: true,
                                        ask: { _, _ in asked += 1; return self.other }, accept: { _ in XCTFail("unrelated") }),
                       .refused(need))
        XCTAssertEqual(asked, AccessPrompt.maxTries)
    }

    func testUnreadableFoldersAreCheckedOncePerFolder() {
        var checks = 0
        let files = (0..<1000).map { trip.appendingPathComponent("\($0).jpg") } + sources(other)
        let unreadable = AccessPrompt.unreadableFolders(of: files) { url in
            checks += 1
            return !url.path.hasPrefix(self.trip.path)
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(unreadable, [trip.path])
        // New-folder mode then asks for the output folder and the unreadable folder, nothing else.
        let out = URL(fileURLWithPath: "/Volumes/T/Out", isDirectory: true)
        var questions: [AccessNeeds.Purpose] = []
        _ = AccessPrompt.run(sources: files, mode: .newFolder(out), covered: [], unreadableFolders: unreadable,
                             caseSensitive: true, ask: { need, _ in questions.append(need.purpose); return need.folder },
                             accept: { _ in })
        XCTAssertEqual(questions, [.saveToOutputFolder, .readOriginals])
    }
}

final class FolderGrantListTests: XCTestCase {
    /// Paths under "/same/" are one folder (like a moved folder or another spelling).
    private let identity: @Sendable (String) -> String = { $0.hasPrefix("/same/") ? "same" : $0 }
    private let bookmark = Data("bookmark".utf8)

    private func grant(_ path: String, _ age: TimeInterval) -> FolderGrantList.Grant {
        FolderGrantList.Grant(path: path, bookmark: bookmark, lastUsed: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    func testLoadValidatesUntrustedData() throws {
        let stored = [grant("/ok", 0), grant("relative", 0), grant("/empty", 0), grant("/big", 0), grant("/same/a", 5),
                      grant("/same/b", 1)]
        var encoded = stored
        encoded[2].bookmark = Data()
        encoded[3].bookmark = Data(count: FolderAccess.maxBookmarkSize + 1)
        let data = try JSONEncoder().encode(encoded)
        let list = FolderGrantList(data: data, identity: identity)
        // Newest first; the older duplicate of the same folder dropped.
        XCTAssertEqual(list.grants.map(\.path), ["/ok", "/same/b"])
        XCTAssertTrue(FolderGrantList(data: Data("not json".utf8)).grants.isEmpty)
        XCTAssertTrue(FolderGrantList(data: nil).grants.isEmpty)
    }

    func testInsertKeepsTheNewestWithinTheLimit() {
        var list = FolderGrantList(grants: (0..<FolderGrantList.maxGrants).map { grant("/g\($0)", TimeInterval($0)) },
                                   identity: identity)
        let dropped = list.insert(path: "/new", bookmark: bookmark, now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(list.grants.count, FolderGrantList.maxGrants)
        XCTAssertEqual(list.grants.first?.path, "/new")
        XCTAssertEqual(dropped.map(\.path), ["/g\(FolderGrantList.maxGrants - 1)"])
        // The same folder under another spelling replaces the old entry.
        list.insert(path: "/same/x", bookmark: bookmark)
        list.insert(path: "/same/y", bookmark: bookmark)
        XCTAssertEqual(list.grants.filter { $0.path.hasPrefix("/same/") }.map(\.path), ["/same/y"])
    }

    func testTouchMovesUsedGrantsToTheFront() {
        var list = FolderGrantList(grants: [grant("/a", 0), grant("/b", 10), grant("/c", 20)], identity: identity)
        XCTAssertEqual(list.grants.map(\.path), ["/a", "/b", "/c"])
        list.touch([2], now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(list.grants.map(\.path), ["/c", "/a", "/b"])
        list.remove(path: "/a")
        XCTAssertEqual(list.grants.map(\.path), ["/c", "/b"])
    }

    func testAFollowedMoveOntoAListedFolderMergesThem() {
        var list = FolderGrantList(grants: [grant("/same/a", 0), grant("/old", 10)], identity: identity)
        let removed = list.update(at: 1, path: "/same/b", bookmark: Data("new".utf8))
        XCTAssertEqual(removed, ["/same/a"])
        XCTAssertEqual(list.grants.map(\.path), ["/same/b"])
        XCTAssertEqual(list.grants.first?.bookmark, Data("new".utf8))
    }
}
