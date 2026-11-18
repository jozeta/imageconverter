import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCLIKit
import ImageconverterCore

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return storage.joined(separator: "\n") }
}

/// `--variant`: parsing, the dry run and a real run.
final class CLIVariantTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-variant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func convert(_ arguments: [String]) throws -> ConvertOptions {
        switch CLIParser.parse(["convert", "a.jpg", "--out", "/tmp/o"] + arguments) {
        case .success(.convert(let options)): return options
        case .failure(let error): throw error
        default: throw CLIUsageError("not a convert command")
        }
    }

    func testVariantQuotedValueWithComma() throws {
        let quoted = try convert(["--variant", "folder=\"/a,b\",format=png,suffix=_x"])
        XCTAssertEqual(quoted.variants.first?.destination, .folder(VariantFolder(path: "/a,b")))
        XCTAssertEqual(quoted.variants.first?.settings.format, .png)
        let escaped = try convert(["--variant", "folder=/a\\,b,format=png,suffix=_x"])
        XCTAssertEqual(escaped.variants.first?.destination, .folder(VariantFolder(path: "/a,b")))
        XCTAssertNotNil(error(["--variant", "folder=\"/a,b,format=png,suffix=_x"]), "an unclosed quote is refused")
    }

    private func error(_ arguments: [String]) -> String? {
        if case .failure(let error) = CLIParser.parse(["convert", "a.jpg", "--out", "/tmp/o"] + arguments) {
            return error.message
        }
        return nil
    }

    func testParsesTheBriefsExampleAndRepeats() throws {
        let options = try convert(["--variant", "name=thumb,format=jpeg,quality=70,long=400,suffix=_thumb",
                                   "--variant=name=web,format=png,percent=50,folder=web"])
        XCTAssertEqual(options.variants.count, 2)
        let thumb = options.variants[0]
        XCTAssertEqual(thumb.name, "thumb")
        XCTAssertEqual(thumb.settings.format, .jpeg)
        XCTAssertEqual(thumb.settings.quality, 0.7, accuracy: 0.0001)
        XCTAssertEqual(thumb.resize, .longestEdge(400))
        XCTAssertEqual(thumb.nameSuffix, "_thumb")
        let web = options.variants[1]
        XCTAssertEqual(web.nameSuffix, "_web", "the suffix defaults to _NAME")
        XCTAssertEqual(web.resize, .percent(50))
        XCTAssertEqual(web.subfolder, "web")
        // Stable ids: parsing again gives an equal command.
        XCTAssertEqual(try convert(["--variant", "name=thumb,format=jpeg,quality=70,long=400,suffix=_thumb",
                                    "--variant=name=web,format=png,percent=50,folder=web"]), options)
    }

    func testAnAbsoluteFolderIsTheOutputsOwnFolder() throws {
        let options = try convert(["--variant", "name=web,folder=/tmp/web/../site",
                                   "--variant", "name=home,folder=~/Pictures/thumbs",
                                   "--variant", "name=sub,folder=thumbs"])
        XCTAssertEqual(options.variants[0].destination, .folder(VariantFolder(path: "/tmp/site")))
        XCTAssertNil(options.variants[0].subfolder)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/thumbs").path
        XCTAssertEqual(options.variants[1].destination, .folder(VariantFolder(path: home)))
        XCTAssertNil(options.variants[2].destination)
        XCTAssertEqual(options.variants[2].subfolder, "thumbs")
    }

    func testUsageErrors() {
        XCTAssertNotNil(error(["--variant", "format=jpeg"]), "no suffix and no name")
        XCTAssertNotNil(error(["--variant", "suffix=_a,colour=red"]))
        XCTAssertNotNil(error(["--variant", "suffix=_a,format=webp"]))
        XCTAssertNotNil(error(["--variant", "suffix=_a,long=10,width=10"]))
        XCTAssertNotNil(error(["--variant", "suffix=_a,quality=101"]))
        XCTAssertNotNil(error(["--variant", "suffix=_a,percent=0"]))
        XCTAssertNotNil(error(["--variant", "suffix=_a,suffix=_b"]))
        XCTAssertNotNil(error(["--variant", "nonsense"]))
        XCTAssertEqual(error(["--variant", "suffix=_a", "--variant", "suffix=_A"]),
                       "--variant with suffix '_A': another output already uses this suffix.")
        XCTAssertNotNil(error(["--variant", "suffix=  "]))
        XCTAssertNotNil(error((0...8).flatMap { ["--variant", "suffix=_\($0)"] }), "at most 8")
        XCTAssertNil(error((0..<8).flatMap { ["--variant", "suffix=_\($0)"] }))
    }

    func testVariantsReplaceThePresetsExtraOutputs() throws {
        var options = ConvertOptions()
        options.variants = [OutputVariant(name: "CLI", nameSuffix: "_cli")]
        let base = Pipeline(extraOutputs: [OutputVariant(name: "Preset", nameSuffix: "_preset")])
        XCTAssertEqual(ConvertCommand.applyOverrides(options, to: base).extraOutputs.map(\.name), ["CLI"])
        XCTAssertEqual(ConvertCommand.applyOverrides(ConvertOptions(), to: base).extraOutputs.map(\.name), ["Preset"])
    }

    // MARK: Running

    private func writePNG(_ name: String) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                        1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private struct Outcome {
        let code: Int32
        let out: String
        let err: String
    }

    private func run(_ arguments: [String], writable: [OutputFormat]? = nil) async -> Outcome {
        let out = Collected(), err = Collected()
        var environment = CLIEnvironment(
            out: { out.add($0) }, err: { err.add($0) }, presetDirectory: root.appendingPathComponent("presets"),
            jobDirectory: root.appendingPathComponent("jobs"), trash: { try FileManager.default.removeItem(at: $0) },
            cancel: CancelToken())
        if let writable { environment.writableFormats = writable }
        let code = await CLIRunner.main(arguments, environment: environment)
        return Outcome(code: code, out: out.text, err: err.text)
    }

    func testDryRunListsEveryOutputAndWritesNothing() async throws {
        let source = try writePNG("in.png")
        let outDir = root.appendingPathComponent("never")
        let result = await run(["convert", source.path, "--out", outDir.path, "--dry-run",
                                "--variant", "name=thumb,long=16,suffix=_thumb",
                                "--variant", "name=Web,format=png,suffix=-web"])
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertTrue(result.out.contains("in.jpg"), result.out)
        XCTAssertTrue(result.out.contains("  + thumb: -> \(outDir.path)/in_thumb.jpg"), result.out)
        XCTAssertTrue(result.out.contains("  + Web: -> \(outDir.path)/in-web.png"), result.out)
        XCTAssertTrue(result.out.contains("1 of 1 files would be written (and 2 extra outputs)."), result.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path))

        let json = await run(["convert", source.path, "--out", outDir.path, "--dry-run", "--json",
                              "--variant", "name=thumb,long=16,suffix=_thumb"])
        XCTAssertTrue(json.out.contains(#""variant" : "thumb""#), json.out)
    }

    func testAVariantFormatThisMacCantWriteIsAUsageError() async throws {
        let source = try writePNG("in.png")
        let outDir = root.appendingPathComponent("out")
        let result = await run(["convert", source.path, "--out", outDir.path, "--variant", "name=t,format=heic"],
                               writable: [.jpeg, .png])
        XCTAssertEqual(result.code, CLIExit.usage)
        XCTAssertTrue(result.err.contains("this Mac can't write HEIC"), result.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path))
    }

    func testARealRunWritesEveryOutput() async throws {
        let source = try writePNG("in.png")
        let outDir = root.appendingPathComponent("out")
        let result = await run(["convert", source.path, "--out", outDir.path, "--quiet",
                                "--variant", "name=thumb,long=16,suffix=_thumb"])
        XCTAssertEqual(result.code, 0, result.err)
        let files = try FileManager.default.contentsOfDirectory(atPath: outDir.path).sorted()
        XCTAssertEqual(files, ["in.jpg", "in_thumb.jpg"])
        XCTAssertEqual(ImageLoader.pixelSize(of: outDir.appendingPathComponent("in_thumb.jpg"))?.width, 16)
        XCTAssertTrue(result.out.contains("1 of 1 files converted"), result.out)
    }

    func testARealRunWritesIntoTheVariantsOwnFolder() async throws {
        let source = try writePNG("in.png")
        let outDir = root.appendingPathComponent("out")
        let web = root.appendingPathComponent("web")
        let result = await run(["convert", source.path, "--out", outDir.path, "--quiet",
                                "--variant", "name=web,format=png,suffix=_web,folder=\(web.path)"])
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outDir.path), ["in.jpg"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: web.path), ["in_web.png"])
    }

    func testEveryExtraOutputsFolderIsPrinted() async throws {
        let source = try writePNG("in.png")
        let outDir = root.appendingPathComponent("out")
        let web = root.appendingPathComponent("web")
        let arguments = ["convert", source.path, "--out", outDir.path,
                         "--variant", "name=web,suffix=_web,folder=\(web.path)", "--variant", "name=thumb,long=16"]
        for extra in [["--dry-run"], ["--quiet"]] {
            let result = await run(arguments + extra)
            XCTAssertEqual(result.code, 0, result.err)
            XCTAssertTrue(result.err.contains("Extra output “web” → \(web.standardizedFileURL.path)"), result.err)
            XCTAssertTrue(result.err.contains("Extra output “thumb” → \(outDir.standardizedFileURL.path)"), result.err)
        }
    }
}
