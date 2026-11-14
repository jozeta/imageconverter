import XCTest
@testable import ImageconverterCLIKit
import ImageconverterCore

final class CLIParserTests: XCTestCase {
    private func convert(_ arguments: [String]) throws -> ConvertOptions {
        guard case .success(.convert(let options)) = CLIParser.parse(["convert"] + arguments) else {
            throw CLIUsageError("not a convert command")
        }
        return options
    }

    private func error(_ arguments: [String]) -> String? {
        if case .failure(let error) = CLIParser.parse(arguments) { return error.message }
        return nil
    }

    func testSimpleCommands() {
        XCTAssertEqual(CLIParser.parse(["--version"]), .success(.version))
        XCTAssertEqual(CLIParser.parse(["--help"]), .success(.help))
        XCTAssertEqual(CLIParser.parse(["presets", "list", "--json"]), .success(.presetsList(json: true)))
        XCTAssertEqual(CLIParser.parse(["jobs", "list"]), .success(.jobsList(json: false)))
        XCTAssertEqual(CLIParser.parse(["jobs", "run", "Nightly", "--quiet"]),
                       .success(.jobsRun(name: "Nightly", quiet: true, json: false)))
    }

    func testFullConvert() throws {
        let options = try convert(["a.jpg", "dir", "--preset", "Web export", "--out=/tmp/o", "--format", "avif",
                                   "--quality", "70", "--max-size", "500KB", "--resize-long", "1600",
                                   "--strip-gps", "--strip-all", "--report", "csv", "--dry-run", "--quiet"])
        XCTAssertEqual(options.inputs, ["a.jpg", "dir"])
        XCTAssertEqual(options.preset, "Web export")
        XCTAssertEqual(options.outputDirectory, "/tmp/o")
        XCTAssertEqual(options.format, .avif)
        XCTAssertEqual(options.quality, 0.7)
        XCTAssertEqual(options.maxSizeBytes, 500_000)
        XCTAssertEqual(options.resizeLongEdge, 1600)
        XCTAssertTrue(options.stripGPS && options.stripAll && options.dryRun && options.quiet)
        XCTAssertEqual(options.report, .csv)
    }

    func testSizesAndFormats() throws {
        XCTAssertEqual(try CLIParser.maxSize("1.5mb"), 1_500_000)
        XCTAssertEqual(try CLIParser.maxSize("200000"), 200_000)
        XCTAssertThrowsError(try CLIParser.maxSize("0KB"))
        XCTAssertThrowsError(try CLIParser.maxSize("big"))
        XCTAssertEqual(try CLIParser.format("JPG"), .jpeg)
        XCTAssertThrowsError(try CLIParser.format("webp"))
    }

    func testErrors() {
        XCTAssertNotNil(error([]))
        XCTAssertNotNil(error(["frobnicate"]))
        XCTAssertNotNil(error(["convert", "--out", "/o"]), "no inputs")
        XCTAssertNotNil(error(["convert", "a.jpg"]), "no output mode")
        XCTAssertNotNil(error(["convert", "a.jpg", "--out", "/o", "--same-folder"]))
        XCTAssertNotNil(error(["convert", "a.jpg", "--overwrite"]), "needs --yes")
        XCTAssertNil(error(["convert", "a.jpg", "--overwrite", "--yes"]))
        XCTAssertNotNil(error(["convert", "a.jpg", "--out", "/o", "--quality", "101"]))
        XCTAssertNotNil(error(["convert", "a.jpg", "--out", "/o", "--quality"]), "missing value")
        XCTAssertNotNil(error(["convert", "a.jpg", "--out", "/o", "--resize-long", "0"]))
        XCTAssertNotNil(error(["convert", "a.jpg", "--out", "/o", "--bogus"]))
        XCTAssertNotNil(error(["convert", "a.jpg", "--out", "/o", "--preset", "x", "--pipeline", "p.json"]))
        XCTAssertNotNil(error(["convert", "a.jpg", "--out", "/o", "--suffix", "_x"]))
        XCTAssertNotNil(error(["convert", "a.jpg", "--out", "/o", "--json", "--report", "csv"]))
        XCTAssertNotNil(error(["jobs", "run"]))
        XCTAssertNotNil(error(["presets", "remove"]))
    }

    func testOverridesApplyOnTopOfPipeline() throws {
        var options = ConvertOptions()
        options.format = .png
        options.resizeLongEdge = 800
        options.stripGPS = true
        options.maxSizeBytes = 100_000
        let base = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(100))))],
                            output: OutputSettings(format: .jpeg, quality: 0.5))
        let result = ConvertCommand.applyOverrides(options, to: base)
        XCTAssertEqual(result.steps.count, 1, "the existing resize step is reused")
        guard case .resize(let resize) = result.steps[0].operation else { return XCTFail("no resize") }
        XCTAssertEqual(resize.mode, .longestEdge(800))
        XCTAssertEqual(result.output.format, .png)
        XCTAssertEqual(result.output.quality, 0.5, "untouched settings stay")
        XCTAssertEqual(result.output.compression, .maxSize(bytes: 100_000))
        XCTAssertTrue(result.metadata.isActive)
        XCTAssertEqual(result.metadata.location, .remove)
        XCTAssertEqual(ConvertCommand.applyOverrides(options, to: Pipeline()).steps.count, 1)
    }
}
