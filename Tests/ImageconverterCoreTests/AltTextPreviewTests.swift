import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// What the model is shown, and the preview's alt text.
final class AltTextPreviewTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let altPath = "Iptc4xmpCore:AltTextAccessibility"

    private func altOptions(description: Bool = false) -> MetadataOptions {
        var options = MetadataOptions(isEnabled: true, removeLocation: false)
        options.generateAltText = true
        options.altTextAsDescription = description
        return options
    }

    private func run(_ url: URL, metadata: MetadataOptions, steps: [PipelineStep] = [],
                     format: OutputFormat = .jpeg, generator: any AltTextGenerator,
                     extraOutputs: [OutputVariant] = []) async throws -> (WrittenFile, BatchReport) {
        let pipeline = Pipeline(steps: steps, output: OutputSettings(format: format), metadata: metadata,
                                extraOutputs: extraOutputs)
        let out = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        let report = await BatchRunner.run([InputItem(source: url, relativeDirectory: "")], pipeline: pipeline,
                                           mode: .newFolder(out), altText: generator)
        XCTAssertEqual(report.failures, [])
        return (try WrittenFile(url: try XCTUnwrap(report.written.first)), report)
    }

    private func source(_ name: String = "a.jpg", type: UTType = .jpeg, width: Int = 120, height: Int = 80) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.noise(width: width, height: height), to: url, type: type)
        return url
    }

    // MARK: What the model sees

    func testModelSeesTheImageAfterThePixelStepsAtMost1024Pixels() async throws {
        let url = try source("big.jpg", width: 3000, height: 1000)
        let generator = FakeAltTextGenerator()
        let crop = PipelineStep(operation: .crop(CropOptions(mode: .aspect(width: 1, height: 1))))
        _ = try await run(url, metadata: altOptions(), steps: [crop], generator: generator)
        let seen = try XCTUnwrap(generator.recorded.first)
        XCTAssertEqual(seen.width, 1000)
        XCTAssertEqual(seen.height, 1000)
        let wide = try source("wide.jpg", width: 3000, height: 1000)
        let other = FakeAltTextGenerator()
        _ = try await run(wide, metadata: altOptions(), steps: [rotate], generator: other)
        XCTAssertEqual(other.recorded.first?.width, 341)
        XCTAssertEqual(other.recorded.first?.height, 1024)
    }

    func testRedactIsAppliedBeforeTheModelSeesTheImage() throws {
        let url = root.appendingPathComponent("red.png")
        try TestImages.write(TestImages.make(width: 200, height: 100, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                             to: url, type: .png)
        let fill = RedactOptions(target: .faces, style: .fill, fillColor: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
                                 padding: 0)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .redact(fill))], output: OutputSettings(format: .png),
                                metadata: altOptions())
        let generator = FakeAltTextGenerator()
        var options = ItemRunOptions()
        options.focus = FocusContext(detector: FakeVisionDetector(faces: [CGRect(x: 0, y: 0, width: 0.5, height: 1)]))
        options.altText = generator
        _ = try BatchRunner.encodeItem(url, pipeline: pipeline, assets: WatermarkAssets.load(for: pipeline, maxPixels: 1 << 28),
                                       maxPixels: 250_000_000, options: options)
        let seen = try XCTUnwrap(generator.recorded.first)
        let left = TestImages.pixel(of: seen, x: 50, y: 50)
        let right = TestImages.pixel(of: seen, x: 150, y: 50)
        XCTAssertGreaterThan(left.green, 240, "the redacted half reaches the model filled")
        XCTAssertLessThan(left.red, 15)
        XCTAssertGreaterThan(right.red, 240, "the rest is untouched")
    }

    /// The size estimate and the quality ladder use the standard generator's place, swapped here for a fake that
    /// would answer: neither asks it, and neither output carries alt text.
    func testSizeEstimateAndQualityLadderNeverGenerate() throws {
        let url = try source()
        let pipeline = Pipeline(steps: [rotate], output: OutputSettings(format: .jpeg), metadata: altOptions())
        let generator = FakeAltTextGenerator()
        let standard = AltText.standardGenerator
        AltText.standardGenerator = generator
        defer { AltText.standardGenerator = standard }
        let item = InputItem(source: url, relativeDirectory: "")
        let estimate = try SizeEstimator.render(item: item, pipeline: pipeline)
        XCTAssertNil(estimate.note)
        let rungs = try QualityLadder.render(item: item, pipeline: pipeline, qualities: [0.5])
        XCTAssertEqual(rungs.count, 1)
        XCTAssertNil(try WrittenFile.decode(try XCTUnwrap(rungs.first).data).xmp(altPath))
        XCTAssertTrue(generator.recorded.isEmpty, "the estimate and the ladder never ask the model")
        // The same fake in the standard place does reach a batch (so the check above can fail).
        let out = root.appendingPathComponent("std", isDirectory: true)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await BatchRunner.run([item], pipeline: pipeline, mode: .newFolder(out))
            semaphore.signal()
        }
        semaphore.wait()
        XCTAssertEqual(generator.recorded.count, 1)
    }

    func testOrientedSourceReachesTheModelUprightOnTheLosslessPath() async throws {
        // Stored 200 × 100, red left, blue right, with orientation 6 (shown turned 90° clockwise: 100 × 200, red on top).
        let url = root.appendingPathComponent("oriented.jpg")
        let stored = TestImages.twoColor(width: 200, height: 100, left: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                         right: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        try TestImages.write(stored, to: url, type: .jpeg, properties: [kCGImagePropertyOrientation as String: 6])
        let generator = FakeAltTextGenerator()
        let (_, report) = try await run(url, metadata: altOptions(), generator: generator)
        XCTAssertEqual(report.entries.first?.note, LosslessMetadata.pixelsUntouchedNote + "; " + AltText.generatedNote)
        let seen = try XCTUnwrap(generator.recorded.first)
        XCTAssertEqual(seen.width, 100)
        XCTAssertEqual(seen.height, 200)
        XCTAssertGreaterThan(TestImages.pixel(of: seen, x: 50, y: 30).red, 200, "red on top")
        XCTAssertGreaterThan(TestImages.pixel(of: seen, x: 50, y: 170).blue, 200, "blue at the bottom")
    }

    func testPreviewDoesNotGenerateWhatTheBatchWouldNotWrite() async throws {
        let generator = FakeAltTextGenerator()
        let renderer = PreviewRenderer(altText: generator)
        var options = altOptions()
        options.removeXMP = true
        let pipeline = Pipeline(steps: [rotate], output: OutputSettings(format: .jpeg), metadata: options)
        guard case .ready(let result) = await renderer.render(item: InputItem(source: try source(), relativeDirectory: ""),
                                                              index: 0, pipeline: pipeline) else {
            return XCTFail("no preview")
        }
        let outcome = await renderer.altText(for: try XCTUnwrap(result.altTextRequest))
        XCTAssertEqual(outcome, .failed(AltText.removeXMPReason))
        XCTAssertTrue(generator.recorded.isEmpty)
    }

    // MARK: Preview

    func testPreviewAsksOncePerFileVersionAndPixelSteps() async throws {
        let url = try source()
        let generator = FakeAltTextGenerator()
        let renderer = PreviewRenderer(altText: generator)
        let item = InputItem(source: url, relativeDirectory: "")
        var pipeline = Pipeline(steps: [rotate], output: OutputSettings(format: .jpeg), metadata: altOptions())
        guard case .ready(let first) = await renderer.render(item: item, index: 0, pipeline: pipeline) else {
            return XCTFail("no preview")
        }
        let request = try XCTUnwrap(first.altTextRequest)
        let outcome = await renderer.altText(for: request)
        XCTAssertEqual(outcome, .text("A red square on a white table."))
        // Another output setting: same pixels, same key, no new question.
        pipeline.output.quality = 0.3
        guard case .ready(let second) = await renderer.render(item: item, index: 0, pipeline: pipeline) else {
            return XCTFail("no preview")
        }
        XCTAssertEqual(second.altTextRequest, request)
        _ = await renderer.altText(for: try XCTUnwrap(second.altTextRequest))
        let asked = await renderer.altTextRequests
        XCTAssertEqual(asked, 1)
        // Another pixel step: asked again.
        pipeline.steps.append(PipelineStep(operation: .crop(CropOptions(mode: .aspect(width: 1, height: 1)))))
        guard case .ready(let third) = await renderer.render(item: item, index: 0, pipeline: pipeline) else {
            return XCTFail("no preview")
        }
        XCTAssertNotEqual(third.altTextRequest, request)
        // No alt text asked for: no request.
        pipeline.metadata.generateAltText = false
        guard case .ready(let fourth) = await renderer.render(item: item, index: 0, pipeline: pipeline) else {
            return XCTFail("no preview")
        }
        XCTAssertNil(fourth.altTextRequest)
    }

    func testPreviewReportsAnUnavailableModel() async throws {
        let renderer = PreviewRenderer(altText: FakeAltTextGenerator(availability: .deviceNotEligible))
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), metadata: altOptions())
        guard case .ready(let result) = await renderer.render(item: InputItem(source: try source(), relativeDirectory: ""),
                                                              index: 0, pipeline: pipeline) else {
            return XCTFail("no preview")
        }
        let outcome = await renderer.altText(for: try XCTUnwrap(result.altTextRequest))
        XCTAssertEqual(outcome, .failed(AltTextAvailability.deviceNotEligible.reason ?? ""))
        XCTAssertEqual(outcome.note, "Alt text not generated: this Mac doesn't support Apple Intelligence")
    }

    private var rotate: PipelineStep { PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw90))) }
}
