import XCTest
@testable import ImageconverterCore

final class FileCommitterTests: XCTestCase {
    private var dir: URL!
    private let files = FileManager.default

    override func setUpWithError() throws { dir = try TestImages.tempDir() }

    override func tearDown() {
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? files.removeItem(at: dir)
    }

    private func tempFiles(in directory: URL) -> [String] {
        ((try? files.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(FileCommitter.tempPrefix) }
    }

    private func plan(source: URL, destination: URL, replaces: Bool = false,
                      trashes: Bool = false) -> PlannedOutput {
        PlannedOutput(item: InputItem(source: source, relativeDirectory: ""), destination: destination,
                      replacesSource: replaces, trashesSource: trashes)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    func testWritesNewFileAndCreatesFolders() throws {
        let dest = dir.appendingPathComponent("a/b/out.png")
        try FileCommitter.commit(Data("new".utf8),
                                 for: plan(source: dir.appendingPathComponent("in.jpg"), destination: dest))
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertTrue(tempFiles(in: dest.deletingLastPathComponent()).isEmpty)
    }

    func testReplacesInPlace() throws {
        let file = dir.appendingPathComponent("x.png")
        try Data("old".utf8).write(to: file)
        try FileCommitter.commit(Data("new".utf8), for: plan(source: file, destination: file, replaces: true))
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        XCTAssertTrue(tempFiles(in: dir).isEmpty)
    }

    func testTrashesSourceOnFormatChange() throws {
        let source = dir.appendingPathComponent("x.jpg")
        try Data("old".utf8).write(to: source)
        let dest = dir.appendingPathComponent("x.png")
        let recorder = Recorder()
        try FileCommitter.commit(Data("new".utf8), for: plan(source: source, destination: dest, trashes: true),
                                 trash: { recorder.add($0) })
        XCTAssertEqual(recorder.all, [source])
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertTrue(tempFiles(in: dir).isEmpty)
    }

    func testTrashFailureKeepsNewFileAndThrows() throws {
        let source = dir.appendingPathComponent("x.jpg")
        try Data("old".utf8).write(to: source)
        let dest = dir.appendingPathComponent("x.png")
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        XCTAssertThrowsError(try FileCommitter.commit(
            Data("new".utf8), for: plan(source: source, destination: dest, trashes: true),
            trash: { _ in throw Boom() })) { error in
            XCTAssertEqual(error as? ConversionError,
                           .writeFailed("Converted, but couldn't move the original to the Trash: boom"))
        }
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertTrue(tempFiles(in: dir).isEmpty)
    }

    func testNoTrashWhenWriteFails() throws {
        let source = dir.appendingPathComponent("x.jpg")
        let dest = dir.appendingPathComponent("x.png")
        try Data("keep".utf8).write(to: dest)
        let recorder = Recorder()
        XCTAssertThrowsError(try FileCommitter.commit(
            Data("new".utf8), for: plan(source: source, destination: dest, trashes: true),
            trash: { recorder.add($0) }))
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testExistingDestinationIsNotClobbered() throws {
        let dest = dir.appendingPathComponent("out.png")
        try Data("keep".utf8).write(to: dest)
        XCTAssertThrowsError(try FileCommitter.commit(
            Data("new".utf8), for: plan(source: dir.appendingPathComponent("in.jpg"), destination: dest))) {
            guard case .writeFailed = $0 as? ConversionError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: dest), Data("keep".utf8))
        XCTAssertTrue(tempFiles(in: dir).isEmpty)
    }

    func testFailureLeavesNoTempFile() throws {
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try files.createDirectory(at: locked, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try FileCommitter.commit(
            Data("new".utf8),
            for: plan(source: dir.appendingPathComponent("in.jpg"),
                      destination: locked.appendingPathComponent("out.png")))) {
            guard case .writeFailed = $0 as? ConversionError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(tempFiles(in: locked).isEmpty)
    }
}
