import XCTest
@testable import ImageconverterCore

/// Review focus 3 and 4: replacing the installed app on temp folders with an injected Trash. Nothing is moved
/// when a step before the swap fails; a failure after the old app went to the Trash puts it back.
final class UpdateReplacerTests: XCTestCase {
    private var root: URL!
    private var installed: URL!
    private var new: URL!
    private var trashFolder: URL!

    /// Trash = a temp folder; each operation can be made to fail.
    private final class FakeOperations: UpdateFileOperations {
        let trashFolder: URL
        var failTrash = false
        var trashReturnsNil = false
        var failMoveCount = 0
        var moves: [(URL, URL)] = []

        init(trashFolder: URL) { self.trashFolder = trashFolder }

        func trash(_ url: URL) throws -> URL? {
            if failTrash { throw CocoaError(.fileWriteNoPermission) }
            let destination = trashFolder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return trashReturnsNil ? nil : destination
        }

        func move(_ source: URL, to destination: URL) throws {
            moves.append((source, destination))
            if failMoveCount > 0 {
                failMoveCount -= 1
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("update-replace-\(UUID().uuidString)")
        installed = root.appendingPathComponent("Applications/imageconverter.app")
        new = root.appendingPathComponent("work/imageconverter.app")
        trashFolder = root.appendingPathComponent("Trash")
        for (app, marker) in [(installed!, "old"), (new!, "new")] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/marker"))
        }
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func marker(_ app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("Contents/marker"))).flatMap { String(data: $0, encoding: .utf8) }
    }

    private var trashed: URL { trashFolder.appendingPathComponent("imageconverter.app") }

    func testReplacesTheAppAndTrashesTheOldOne() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        try UpdateReplacer.replace(installed, with: new, using: operations)
        XCTAssertEqual(marker(installed), "new")
        XCTAssertEqual(marker(trashed), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }

    func testMissingNewAppMovesNothing() throws {
        try FileManager.default.removeItem(at: new)
        let operations = FakeOperations(trashFolder: trashFolder)
        XCTAssertThrowsError(try UpdateReplacer.replace(installed, with: new, using: operations))
        XCTAssertEqual(marker(installed), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testMissingInstalledAppMovesNothing() throws {
        try FileManager.default.removeItem(at: installed)
        let operations = FakeOperations(trashFolder: trashFolder)
        XCTAssertThrowsError(try UpdateReplacer.replace(installed, with: new, using: operations))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(marker(new), "new")
    }

    func testTrashFailureLeavesTheOldAppInPlace() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        operations.failTrash = true
        XCTAssertThrowsError(try UpdateReplacer.replace(installed, with: new, using: operations)) { error in
            guard case .installFailed? = error as? UpdateError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(marker(installed), "old")
        XCTAssertEqual(marker(new), "new")
        XCTAssertTrue(operations.moves.isEmpty)
    }

    func testMoveFailureAfterTrashingRestoresTheOldApp() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        operations.failMoveCount = 1
        XCTAssertThrowsError(try UpdateReplacer.replace(installed, with: new, using: operations)) { error in
            guard case .installFailed(let reason)? = error as? UpdateError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("restored"), reason)
        }
        XCTAssertEqual(marker(installed), "old", "old app back at its path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertEqual(operations.moves.map(\.1), [installed, installed])
    }

    func testRestoreFailureSaysWhereTheOldAppIs() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        operations.failMoveCount = 2
        XCTAssertThrowsError(try UpdateReplacer.replace(installed, with: new, using: operations)) { error in
            guard case .installFailed(let reason)? = error as? UpdateError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("Trash"), reason)
        }
        XCTAssertEqual(marker(trashed), "old")
    }

    func testTrashWithoutALocationStillInstallsOrSaysWhereTheOldAppIs() throws {
        // The old app is gone from its path either way; leaving the user without any app would be worse.
        let operations = FakeOperations(trashFolder: trashFolder)
        operations.trashReturnsNil = true
        try UpdateReplacer.replace(installed, with: new, using: operations)
        XCTAssertEqual(marker(installed), "new")

        try? FileManager.default.removeItem(at: root)
        try setUpWithError()
        let failing = FakeOperations(trashFolder: trashFolder)
        failing.trashReturnsNil = true
        failing.failMoveCount = 1
        XCTAssertThrowsError(try UpdateReplacer.replace(installed, with: new, using: failing)) { error in
            guard case .installFailed(let reason)? = error as? UpdateError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("Trash"), reason)
        }
    }

    func testSystemOperationsOnTempFolders() throws {
        // The real FileManager move (no Trash: the real Trash is not touched by tests).
        let target = root.appendingPathComponent("moved.app")
        try SystemUpdateFileOperations().move(new, to: target)
        XCTAssertEqual(marker(target), "new")
    }
}
