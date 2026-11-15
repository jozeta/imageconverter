import XCTest
@testable import ImageconverterCore

/// Review focus 3 and 4: replacing the installed app on temp folders with injected failures at every step. The swap
/// never leaves the folder holding the app (no restore from the Trash, which the sandbox can't reach): the verified
/// app is copied in as a hidden sibling and checked again there, the old app is renamed aside, the copy renamed into
/// place, and only then the old one trashed. After any failure the old app or the new one is at the app's path.
final class UpdateReplacerTests: XCTestCase {
    private var root: URL!
    private var applications: URL!
    private var installed: URL!
    private var verified: URL!
    private var trashFolder: URL!

    private enum Step: Hashable { case copy, renameOld, renameNew, restore, trash, remove }

    /// Real file operations on temp folders; each step can be made to fail (Trash = a temp folder).
    private final class FakeOperations: UpdateFileOperations {
        let trashFolder: URL
        var failing: Set<Step> = []
        var partialCopy = false
        var log: [Step] = []

        init(trashFolder: URL) { self.trashFolder = trashFolder }

        private func step(_ step: Step) throws {
            log.append(step)
            if failing.contains(step) { throw CocoaError(.fileWriteUnknown) }
        }

        func copy(_ source: URL, to destination: URL) throws {
            if partialCopy, failing.contains(.copy) {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            try step(.copy)
            try FileManager.default.copyItem(at: source, to: destination)
        }

        func move(_ source: URL, to destination: URL) throws {
            let name = source.lastPathComponent
            if name.hasPrefix(UpdateReplacer.oldPrefix) {
                try step(.restore)
            } else if name.hasPrefix(UpdateReplacer.stagingPrefix) {
                try step(.renameNew)
            } else {
                try step(.renameOld)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }

        func trash(_ url: URL) throws {
            try step(.trash)
            try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
        }

        func remove(_ url: URL) throws {
            try step(.remove)
            try FileManager.default.removeItem(at: url)
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("update-replace-\(UUID().uuidString)")
        applications = root.appendingPathComponent("Applications")
        installed = applications.appendingPathComponent("imageconverter.app")
        verified = root.appendingPathComponent("work/unpacked/imageconverter.app")
        trashFolder = root.appendingPathComponent("Trash")
        for (app, marker) in [(installed!, "old"), (verified!, "new")] {
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

    /// Hidden staging or old siblings left in the Applications folder.
    private var leftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []).filter { $0.hasPrefix(".") }
    }

    private func stage(_ operations: FakeOperations, verify: (URL) throws -> Void = { _ in }) throws -> URL {
        try UpdateReplacer.stage(verified, beside: installed, using: operations, verify: verify)
    }

    // MARK: Success

    func testStagesChecksSwapsAndTrashesTheOldApp() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        var checked: [URL] = []
        let staged = try stage(operations) { checked.append($0) }
        XCTAssertEqual(staged.deletingLastPathComponent().path, applications.path, "staged beside the installed app")
        XCTAssertTrue(staged.lastPathComponent.hasPrefix(".imageconverter-update-") && staged.pathExtension == "app")
        XCTAssertEqual(checked, [staged], "the staged copy itself is verified again")
        XCTAssertEqual(marker(installed), "old", "staging doesn't touch the installed app")

        let note = try UpdateReplacer.swap(installed, with: staged, using: operations)
        XCTAssertNil(note)
        XCTAssertEqual(marker(installed), "new")
        XCTAssertEqual(leftovers, [])
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trashFolder.path)
        XCTAssertEqual(trashed.count, 1)
        XCTAssertTrue(trashed[0].hasPrefix(UpdateReplacer.oldPrefix))
        XCTAssertEqual(operations.log, [.copy, .renameOld, .renameNew, .trash])
    }

    // MARK: Staging failures: the installed app is never touched

    func testCopyFailureRemovesThePartialCopy() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        operations.failing = [.copy]
        operations.partialCopy = true
        XCTAssertThrowsError(try stage(operations)) { error in
            guard case .installFailed? = error as? UpdateError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(marker(installed), "old")
        XCTAssertEqual(leftovers, [])
    }

    func testFailedCheckOfTheStagedCopyRemovesIt() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        XCTAssertThrowsError(try stage(operations) { _ in throw UpdateError.signatureRejected }) { error in
            XCTAssertEqual(error as? UpdateError, .signatureRejected)
        }
        XCTAssertEqual(marker(installed), "old")
        XCTAssertEqual(leftovers, [])
    }

    func testMissingAppsAreRefusedBeforeCopying() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        try FileManager.default.removeItem(at: installed)
        XCTAssertThrowsError(try stage(operations))
        XCTAssertEqual(operations.log, [])
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("Contents/marker"))
        try FileManager.default.removeItem(at: verified)
        XCTAssertThrowsError(try stage(operations))
        XCTAssertEqual(marker(installed), "old")
    }

    func testDiscardRemovesTheStagedCopy() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        let staged = try stage(operations)
        UpdateReplacer.discard(staged, using: operations)
        XCTAssertEqual(leftovers, [])
        XCTAssertEqual(marker(installed), "old")
    }

    // MARK: Swap failures

    func testRenamingTheOldAppFailsLeavesItAndRemovesTheCopy() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        let staged = try stage(operations)
        operations.failing = [.renameOld]
        XCTAssertThrowsError(try UpdateReplacer.swap(installed, with: staged, using: operations))
        XCTAssertEqual(marker(installed), "old")
        XCTAssertEqual(leftovers, [])
    }

    func testRenamingTheNewAppFailsPutsTheOldOneBack() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        let staged = try stage(operations)
        operations.failing = [.renameNew]
        XCTAssertThrowsError(try UpdateReplacer.swap(installed, with: staged, using: operations)) { error in
            guard case .installFailed(let reason)? = error as? UpdateError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("restored"), reason)
        }
        XCTAssertEqual(marker(installed), "old", "old app back at its path")
        XCTAssertEqual(leftovers, [], "the staged copy is removed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashFolder.path), [], "nothing trashed")
    }

    func testRestoreFailureSaysWhereTheOldAppIs() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        let staged = try stage(operations)
        operations.failing = [.renameNew, .restore]
        XCTAssertThrowsError(try UpdateReplacer.swap(installed, with: staged, using: operations)) { error in
            guard case .installFailed(let reason)? = error as? UpdateError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains(UpdateReplacer.oldPrefix), reason)
        }
        let old = leftovers.filter { $0.hasPrefix(UpdateReplacer.oldPrefix) }
        XCTAssertEqual(old.count, 1, "the old app is still in the folder, under its hidden name")
        XCTAssertEqual(marker(applications.appendingPathComponent(old[0])), "old")
    }

    func testTrashFailureRemovesTheOldApp() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        let staged = try stage(operations)
        operations.failing = [.trash]
        XCTAssertNil(try UpdateReplacer.swap(installed, with: staged, using: operations))
        XCTAssertEqual(marker(installed), "new")
        XCTAssertEqual(leftovers, [])
    }

    func testTrashAndRemoveFailureIsANoteNotAnError() throws {
        let operations = FakeOperations(trashFolder: trashFolder)
        let staged = try stage(operations)
        operations.failing = [.trash, .remove]
        let note = try UpdateReplacer.swap(installed, with: staged, using: operations)
        XCTAssertEqual(marker(installed), "new", "the update is installed")
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains(UpdateReplacer.oldPrefix) == true, note ?? "")
    }

    // MARK: Real operations

    func testSystemOperationsOnTempFolders() throws {
        // Real copy, move and remove (not the Trash: tests never touch the real Trash).
        let operations = SystemUpdateFileOperations()
        let copy = root.appendingPathComponent("copy.app")
        try operations.copy(verified, to: copy)
        XCTAssertEqual(marker(copy), "new")
        let moved = root.appendingPathComponent("moved.app")
        try operations.move(copy, to: moved)
        XCTAssertEqual(marker(moved), "new")
        try operations.remove(moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
    }
}
