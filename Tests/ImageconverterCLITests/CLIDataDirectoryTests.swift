import XCTest
@testable import ImageconverterCLIKit
import ImageconverterCore

final class CLIDataDirectoryTests: XCTestCase {
    func testSameBundleIdentifierAsTheUpdateCheck() {
        XCTAssertEqual(CLIDataDirectory.bundleIdentifier, UpdatePolicy.bundleIdentifier)
    }

    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private let container = "/Users/someone/Library/Containers/io.github.jozeta.imageconverter/Data/Library/"
        + "Application Support/imageconverter"

    func testContainerWinsWhenItExists() {
        let chosen = CLIDataDirectory.resolve(home: home, directoryExists: { $0.path == self.container })
        XCTAssertEqual(chosen.path, container)
    }

    func testPlainFolderWithoutAContainer() {
        let chosen = CLIDataDirectory.resolve(home: home, directoryExists: { _ in false })
        XCTAssertEqual(chosen.path, "/Users/someone/Library/Application Support/imageconverter")
    }

    func testOverrideWins() {
        let chosen = CLIDataDirectory.resolve(home: home, override: "/tmp/data/../elsewhere",
                                              directoryExists: { _ in true })
        XCTAssertEqual(chosen.path, "/tmp/elsewhere")
    }

    func testDataDirArgumentIsTakenOut() throws {
        let (rest, value) = try CLIDataDirectory.extract(["--data-dir", "/d", "presets", "list"])
        XCTAssertEqual(rest, ["presets", "list"])
        XCTAssertEqual(value, "/d")
        let equals = try CLIDataDirectory.extract(["presets", "list", "--data-dir=/e"])
        XCTAssertEqual(equals.dataDirectory, "/e")
        // After "--" it is a file name.
        let terminated = try CLIDataDirectory.extract(["convert", "--", "--data-dir"])
        XCTAssertEqual(terminated.arguments, ["convert", "--", "--data-dir"])
        XCTAssertNil(terminated.dataDirectory)
        XCTAssertThrowsError(try CLIDataDirectory.extract(["presets", "--data-dir"]))
        XCTAssertThrowsError(try CLIDataDirectory.extract(["--data-dir=a", "--data-dir=b"]))
    }

    func testDataDirReadsPresetsFromThatFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-data-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try PresetStore(directory: root.appendingPathComponent("presets")).save(Preset(name: "Mine", pipeline: Pipeline()))
        let lines = LockedLines()
        let environment = CLIEnvironment(out: { lines.add($0) }, err: { _ in },
                                         presetDirectory: URL(fileURLWithPath: "/nonexistent"),
                                         jobDirectory: URL(fileURLWithPath: "/nonexistent"))
        let code = await CLIRunner.main(["--data-dir", root.path, "presets", "list"], environment: environment)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(lines.text.contains("Mine"), lines.text)
        let usage = await CLIRunner.main(["presets", "list", "--data-dir"], environment: environment)
        XCTAssertEqual(usage, CLIExit.usage)
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
