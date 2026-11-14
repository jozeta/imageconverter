import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCLIKit
import ImageconverterCore

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    var text: String { all.joined(separator: "\n") }
}

final class CLIRunnerTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writePNG(_ name: String, width: Int = 64, height: Int = 32) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                        1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func environment(_ out: Lines, _ err: Lines) -> CLIEnvironment {
        CLIEnvironment(out: { out.add($0) }, err: { err.add($0) },
                       presetDirectory: root.appendingPathComponent("presets"),
                       jobDirectory: root.appendingPathComponent("jobs"),
                       trash: { try FileManager.default.removeItem(at: $0) })
    }

    private struct Outcome {
        let code: Int32
        let out: String
        let err: String
    }

    private func run(_ arguments: [String]) async -> Outcome {
        let out = Lines(), err = Lines()
        let code = await CLIRunner.main(arguments, environment: environment(out, err))
        return Outcome(code: code, out: out.text, err: err.text)
    }

    func testVersionAndUsageErrorExitCodes() async {
        let version = await run(["--version"])
        XCTAssertEqual(version.code, 0)
        XCTAssertEqual(version.out, "imageconverter \(AppInfo.version)")
        let bad = await run(["convert"])
        XCTAssertEqual(bad.code, 2)
        XCTAssertTrue(bad.err.contains("--help"))
        let refused = await run(["convert", "x.jpg", "--overwrite"])
        XCTAssertEqual(refused.code, 2)
    }

    func testEndToEndConvertWritesResizedJPEGAndJSON() async throws {
        let source = try writePNG("in.png", width: 400, height: 200)
        let outDir = root.appendingPathComponent("out")
        let result = await run(["convert", source.path, "--out", outDir.path, "--format", "jpeg", "--quality", "60",
                                "--resize-long", "100", "--strip-gps", "--json"])
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertEqual(result.err, "", "--json is quiet")
        let written = outDir.appendingPathComponent("in.jpg")
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 100)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        let summary = try XCTUnwrap(json["summary"] as? [String: Any])
        XCTAssertEqual(summary["succeeded"] as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original is untouched")
    }

    func testDryRunWritesNothing() async throws {
        let source = try writePNG("in.png")
        let outDir = root.appendingPathComponent("never")
        let result = await run(["convert", source.path, "--out", outDir.path, "--dry-run"])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.out.contains("in.jpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path))
        let same = await run(["convert", source.path, "--same-folder", "--format", "png", "--dry-run"])
        XCTAssertEqual(same.code, 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(files, ["in.png"])
    }

    func testNothingToDoAndFailures() async throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let none = await run(["convert", empty.path, "--out", root.appendingPathComponent("o").path, "--quiet"])
        XCTAssertEqual(none.code, 3)
        let corrupt = root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: corrupt)
        let failed = await run(["convert", corrupt.path, "--out", root.appendingPathComponent("o2").path, "--quiet"])
        XCTAssertEqual(failed.code, 1)
        XCTAssertTrue(failed.out.contains("failed:"))
    }

    func testPresetPipelineFileAndSameFolder() async throws {
        let source = try writePNG("pic.png")
        let missing = await run(["convert", source.path, "--preset", "Nope", "--same-folder"])
        XCTAssertEqual(missing.code, 2)
        let builtIn = await run(["convert", source.path, "--preset", "archive tiff", "--same-folder", "--suffix", "_t",
                                 "--quiet"])
        XCTAssertEqual(builtIn.code, 0, builtIn.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("pic.tif").path))
        let file = root.appendingPathComponent("p.json")
        try JSONEncoder().encode(Pipeline(output: OutputSettings(format: .png))).write(to: file)
        let viaFile = await run(["convert", source.path, "--pipeline", file.path, "--out",
                                 root.appendingPathComponent("o").path, "--report", "csv", "--quiet"])
        XCTAssertEqual(viaFile.code, 0, viaFile.err)
        XCTAssertTrue(viaFile.out.hasPrefix("\"source\""))
        try Data("{\"hello\":1}".utf8).write(to: file)
        let bad = await run(["convert", source.path, "--pipeline", file.path, "--same-folder"])
        XCTAssertEqual(bad.code, 2)
    }

    func testPresetsList() async {
        let plain = await run(["presets", "list"])
        XCTAssertTrue(plain.out.contains("Web export (built-in)"))
        let json = await run(["presets", "list", "--json"])
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(json.out.utf8)))
    }

    func testJobsListAndRun() async throws {
        let inputs = root.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        _ = try writePNG("watched/a.png")
        // The job runner only takes files that have settled for a couple of seconds.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: inputs.appendingPathComponent("a.png").path)
        let store = JobStore(directory: root.appendingPathComponent("jobs"))
        try store.save(Job(name: "Nightly", pipeline: Pipeline(output: OutputSettings(format: .png)),
                           inputs: [inputs], output: .newFolder(root.appendingPathComponent("jobout"))))
        let list = await run(["jobs", "list"])
        XCTAssertEqual(list.out, "Nightly")
        let ran = await run(["jobs", "run", "nightly", "--quiet"])
        XCTAssertEqual(ran.code, 0, ran.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("jobout/a.png").path))
        let unknown = await run(["jobs", "run", "ghost"])
        XCTAssertEqual(unknown.code, 2)
    }
}
