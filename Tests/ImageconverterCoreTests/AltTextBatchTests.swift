import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// Alt text through the batch, the lossless metadata copy and the preview, with a fake generator.
final class AltTextBatchTests: XCTestCase {

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

    // MARK: Written and read back

    func testAltTextIsWrittenToXMPInEveryRichFormat() async throws {
        for format in MetadataTestSupport.richFormats {
            let (type, ext) = MetadataTestSupport.type(of: format)
            let url = try source("in-\(ext).\(ext)", type: type)
            let generator = FakeAltTextGenerator()
            let (file, report) = try await run(url, metadata: altOptions(), format: format, generator: generator)
            XCTAssertEqual(file.xmp(altPath), "A red square on a white table.", "\(format)")
            XCTAssertEqual(file.xmpArray(altPath), ["A red square on a white table."], "\(format): lang-alt")
            XCTAssertNil(file.xmp("dc:description"), "\(format)")
            XCTAssertEqual(generator.recorded.count, 1, "\(format)")
            XCTAssertFalse(report.notes.contains { $0.text.contains("Alt text") }, "\(format)")
        }
    }

    func testAltTextIsALanguageAlternativeWithXDefault() async throws {
        let (file, _) = try await run(try source(), metadata: altOptions(), steps: [rotate], generator: FakeAltTextGenerator())
        let meta = try XCTUnwrap(file.meta)
        let tag = try XCTUnwrap(CGImageMetadataCopyTagWithPath(meta, nil, altPath as CFString))
        XCTAssertEqual(CGImageMetadataTagGetType(tag), .alternateText)
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(meta, nil, "\(altPath)[x-default]" as CFString) as String?,
                       "A red square on a white table.")
    }

    func testAlsoAsDescriptionSetsEveryDescriptionField() async throws {
        let (file, _) = try await run(try source(), metadata: altOptions(description: true), steps: [rotate],
                                      generator: FakeAltTextGenerator())
        XCTAssertEqual(file.xmp(altPath), "A red square on a white table.")
        XCTAssertEqual(file.xmp("dc:description"), "A red square on a white table.")
        XCTAssertEqual(file.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCCaptionAbstract as String] as? String,
                       "A red square on a white table.")
        XCTAssertEqual(file.sub(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFImageDescription as String] as? String,
                       "A red square on a white table.")
    }

    func testModelTextIsSanitisedBeforeWriting() async throws {
        let raw = "\"Image of a\u{202E} boat\n\non a lake.\u{0000}\""
        let (file, _) = try await run(try source(), metadata: altOptions(description: true), steps: [rotate],
                                      generator: FakeAltTextGenerator(.answer(raw)))
        XCTAssertEqual(file.xmp(altPath), "A boat on a lake.")
        XCTAssertEqual(file.xmp("dc:description"), "A boat on a lake.")
    }

    func testRemoveAllStillWritesTheGeneratedText() async throws {
        var options = altOptions()
        options.removeAll = true
        let (file, _) = try await run(try source(), metadata: options, steps: [rotate], generator: FakeAltTextGenerator())
        XCTAssertEqual(file.xmp(altPath), "A red square on a white table.")
    }

    func testExtraOutputsCarryTheSameTextFromOneGeneration() async throws {
        let generator = FakeAltTextGenerator()
        let variant = OutputVariant(name: "Small", settings: OutputSettings(format: .png),
                                    resize: .longestEdge(40), nameSuffix: "_small")
        let (_, report) = try await run(try source(), metadata: altOptions(), steps: [rotate], generator: generator,
                                        extraOutputs: [variant])
        XCTAssertEqual(report.written.count, 2)
        for url in report.written {
            XCTAssertEqual(try WrittenFile(url: url).xmp(altPath), "A red square on a white table.", url.lastPathComponent)
        }
        XCTAssertEqual(generator.recorded.count, 1)
    }

    // MARK: Lossless metadata path

    func testLosslessCopyWritesAndVerifiesTheAltText() async throws {
        for format in [OutputFormat.jpeg, .heic] where OutputFormat.available().contains(format) {
            let (type, ext) = MetadataTestSupport.type(of: format)
            let url = try source("lossless.\(ext)", type: type, width: 1600, height: 1200)
            let generator = FakeAltTextGenerator()
            let (file, report) = try await run(url, metadata: altOptions(description: true), format: format,
                                               generator: generator)
            let note = try XCTUnwrap(report.entries.first?.note, "\(format)")
            XCTAssertEqual(note, LosslessMetadata.pixelsUntouchedNote, "\(format): no needless re-encode")
            XCTAssertEqual(file.xmp(altPath), "A red square on a white table.", "\(format)")
            XCTAssertEqual(file.xmp("dc:description"), "A red square on a white table.", "\(format)")
            // The model saw an upright ≤ 1024 px thumbnail of the source.
            let seen = try XCTUnwrap(generator.recorded.first)
            XCTAssertEqual(max(seen.width, seen.height), 1024, "\(format)")
            XCTAssertEqual(generator.recorded.count, 1, "\(format)")
        }
    }

    func testLosslessCopyCheckComparesTheAltTextValue() throws {
        let url = try source("check.jpg", width: 64, height: 48)
        var pipeline = Pipeline(output: OutputSettings(format: .jpeg), metadata: altOptions())
        pipeline = pipeline.withGeneratedAltText("Right text.")
        guard case .written(let data, let properties)? = try LosslessMetadata.write(url, pipeline: pipeline,
                                                                                  maxPixels: 250_000_000) else {
            return XCTFail("expected a lossless copy")
        }
        XCTAssertEqual(try WrittenFile.decode(data).xmp(altPath), "Right text.")
        // A copy holding another value for the field counts as not written.
        let otherProperties = Pipeline(output: OutputSettings(format: .jpeg), metadata: altOptions())
            .withGeneratedAltText("Other text.").outputProperties(from: [:], sourceWidth: 64, sourceHeight: 48)
        let other = try XCTUnwrap(LosslessMetadata.reference(otherProperties, format: .jpeg))
        let check = LosslessMetadata.check(data, expected: properties, options: pipeline.metadata, reference: other)
        XCTAssertTrue(check.missing.contains("XMP Iptc4xmpCore:AltTextAccessibility"), "\(check)")
    }

    func testLosslessCopyWithoutAltTextNeedsNoModel() async throws {
        let generator = FakeAltTextGenerator(availability: .modelNotReady)
        var options = altOptions()
        options.generateAltText = false
        let (file, report) = try await run(try source(), metadata: options, generator: generator)
        XCTAssertEqual(report.entries.first?.note, LosslessMetadata.pixelsUntouchedNote)
        XCTAssertNil(file.xmp(altPath))
    }

    // MARK: Failures never fail the item

    func testUnavailableModelGivesANoteAndTheItemContinues() async throws {
        let generator = FakeAltTextGenerator(availability: .modelNotReady)
        let (file, report) = try await run(try source(), metadata: altOptions(), steps: [rotate], generator: generator)
        XCTAssertNil(file.xmp(altPath))
        XCTAssertEqual(report.notes.map(\.text),
                       [AltText.notGeneratedNote(AltTextAvailability.modelNotReady.reason ?? "")])
        XCTAssertTrue(generator.recorded.isEmpty, "an unavailable model is never asked")
    }

    func testUnavailableModelNoteOnALosslessCopy() async throws {
        let generator = FakeAltTextGenerator(availability: .appleIntelligenceNotEnabled)
        let (_, report) = try await run(try source(), metadata: altOptions(), generator: generator)
        XCTAssertEqual(report.entries.first?.note, LosslessMetadata.pixelsUntouchedNote + "; "
                       + "Alt text not generated: Apple Intelligence is turned off in System Settings")
    }

    func testModelErrorEmptyAnswerAndTimeoutAreNotes() async throws {
        let cases: [(FakeAltTextGenerator.Behaviour, String)] = [
            (.fail(AltTextError("the model declined to describe this image")), "the model declined to describe this image"),
            (.answer(" \u{202E}\n "), AltText.emptyAnswer),
        ]
        for (behaviour, reason) in cases {
            var options = altOptions(description: true)
            options.description = "Kept description"
            let (file, report) = try await run(try source("\(UUID().uuidString).jpg"), metadata: options, steps: [rotate],
                                               generator: FakeAltTextGenerator(behaviour))
            XCTAssertEqual(report.notes.map(\.text), [AltText.notGeneratedNote(reason)])
            XCTAssertNil(file.xmp(altPath))
            XCTAssertEqual(file.xmp("dc:description"), "Kept description", "the user's own description stays")
        }
    }

    func testTimeoutEndsTheWaitEvenWhenTheModelIgnoresCancellation() async throws {
        let image = TestImages.make(width: 20, height: 20)
        let started = Date()
        let outcome = try AltText.generateBlocking(for: image, with: FakeAltTextGenerator(.hang(seconds: 5)), timeout: 0.3)
        XCTAssertEqual(outcome, .failed(AltText.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let asyncStarted = Date()
        let asyncOutcome = await AltText.generate(for: image, with: FakeAltTextGenerator(.hang(seconds: 5)), timeout: 0.3)
        XCTAssertEqual(asyncOutcome, .failed(AltText.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(asyncStarted), 2)
        XCTAssertEqual(AltText.timeout, 30)
    }

    func testRemoveXMPSkipsTheModelWithANote() async throws {
        var options = altOptions()
        options.removeXMP = true
        let generator = FakeAltTextGenerator()
        let (_, report) = try await run(try source(), metadata: options, steps: [rotate], generator: generator)
        XCTAssertEqual(report.notes.map(\.text), [AltText.notGeneratedNote(AltText.removeXMPReason)])
        XCTAssertTrue(generator.recorded.isEmpty)
        // Also as the description: still worth generating (EXIF and IPTC hold it).
        options.altTextAsDescription = true
        let (file, _) = try await run(try source("b.jpg"), metadata: options, steps: [rotate], generator: generator)
        XCTAssertEqual(file.sub(kCGImagePropertyIPTCDictionary)?[kCGImagePropertyIPTCCaptionAbstract as String] as? String,
                       "A red square on a white table.")
    }

    private var rotate: PipelineStep { PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw90))) }
}

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

    func testSizeEstimateAndQualityLadderNeverGenerate() throws {
        let url = try source()
        let pipeline = Pipeline(steps: [rotate], output: OutputSettings(format: .jpeg), metadata: altOptions())
        let generator = FakeAltTextGenerator()
        // The estimate path: default item options, no generator.
        let encoded = try BatchRunner.encodeItem(url, pipeline: pipeline, assets: WatermarkAssets.load(for: pipeline,
                                                 maxPixels: 1 << 28), maxPixels: 250_000_000)
        XCTAssertNil(encoded.note)
        XCTAssertNil(try WrittenFile.decode(encoded.data).xmp(altPath))
        _ = try SizeEstimator.render(item: InputItem(source: url, relativeDirectory: ""), pipeline: pipeline)
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
