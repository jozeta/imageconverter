import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// Fix round 1: Redact as a floor for copies, fail closed, structured warnings, text defaults, detection quality,
/// face regions in metadata, insertion order.
final class RedactFloorTests: XCTestCase {
    private let redactFaces = PipelineStep(operation: .redact(RedactOptions(target: .faces)))
    private let copyAll = PipelineStep(operation: .condition(ConditionalStep(then: [.copyOriginal])))
    private let big = ItemFacts(width: 3000, height: 100, format: .png)

    func testACopiedOriginalIsConvertedToRedact() {
        let pipeline = Pipeline(steps: [redactFaces, copyAll], output: OutputSettings(format: .jpeg))
        let resolved = pipeline.resolved(for: big)
        XCTAssertEqual(resolved.disposition, .process)
        XCTAssertEqual(resolved.pipeline.steps, [redactFaces])
        XCTAssertEqual(resolved.pipeline.output.format, .png, "kept in the source's own format")
        XCTAssertTrue(resolved.notes.contains(Redaction.convertedToRedactNote))
        XCTAssertTrue(resolved.pipeline.extraOutputs.isEmpty, "a copy had no extra outputs, nor does its conversion")
    }

    func testThePrivacyConversionKeepsTheRedactStep() {
        var pipeline = Pipeline(steps: [redactFaces, copyAll])
        pipeline.metadata = MetadataOptions(isEnabled: true, removeLocation: true)
        let resolved = pipeline.resolved(for: big)
        XCTAssertEqual(resolved.disposition, .process)
        XCTAssertEqual(resolved.pipeline.steps, [redactFaces])
        XCTAssertTrue(resolved.notes.contains(Redaction.convertedToRedactNote))
    }

    func testADisabledRedactStepIsNoFloor() {
        var disabled = redactFaces
        disabled.isEnabled = false
        XCTAssertEqual(Pipeline(steps: [disabled, copyAll]).resolved(for: big).disposition, .copyOriginal)
    }

    func testExtraOutputsAreRedactedToo() throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 100, height: 100, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                             to: url, type: .png)
        var options = ItemRunOptions()
        options.focus = FocusContext(detector: FakeVisionDetector(faces: [CGRect(x: 0, y: 0, width: 1, height: 1)]))
        let fill = RedactOptions(target: .faces, style: .fill, fillColor: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1))
        let pipeline = Pipeline(steps: [PipelineStep(operation: .redact(fill))], output: OutputSettings(format: .png))
        let encoded = try BatchRunner.encodeItem(url, pipeline: pipeline, assets: .empty,
                                                 maxPixels: ImageLoader.defaultMaxPixels, options: options,
                                                 variants: [OutputVariant(settings: OutputSettings(format: .png),
                                                                          resize: .longestEdge(50))])
        let extra = try XCTUnwrap(try? encoded.variants.first?.outcome.get())
        XCTAssertEqual(try TestImages.pixel(of: extra.data, x: 25, y: 25).green, 255, accuracy: 2)
    }
}

final class RedactFailClosedTests: XCTestCase {
    func testAVisionErrorFailsTheItem() {
        let pipeline = Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions(target: .both)))])
        XCTAssertThrowsError(try pipeline.apply(to: TestImages.make(width: 20, height: 20),
                                                focus: FocusContext(detector: FakeVisionDetector(error: VisionBroke())))) {
            let error = $0 as? ConversionError
            XCTAssertEqual(error, .redactUnchecked(target: .both, reason: "Vision broke"))
            XCTAssertEqual(error?.reason, "Not written: couldn't check for faces and text (Vision broke)")
            XCTAssertEqual(error?.isRetryable, true)
        }
    }

    func testOneFailedDetectionFailsTheItem() {
        let pipeline = Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions(target: .both)))])
        XCTAssertThrowsError(try pipeline.apply(
            to: TestImages.make(width: 20, height: 20),
            focus: FocusContext(detector: HalfBrokenDetector(text: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)]))))
        // Only text asked for: the broken face detection isn't used.
        XCTAssertNoThrow(try Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions(target: .text)))])
            .apply(to: TestImages.make(width: 20, height: 20),
                   focus: FocusContext(detector: HalfBrokenDetector(text: []))))
    }

    func testBatchPrepareFailsInsteadOfWritingUnredacted() throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 50, height: 50), to: url, type: .png)
        var options = ItemRunOptions()
        options.focus = FocusContext(detector: FakeVisionDetector(error: VisionBroke()))
        XCTAssertThrowsError(try BatchRunner.encodeItem(
            url, pipeline: Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions()))]), assets: .empty,
            maxPixels: ImageLoader.defaultMaxPixels, options: options)) {
            XCTAssertEqual(($0 as? ConversionError)?.reason, "Not written: couldn't check for faces (Vision broke)")
        }
    }
}

final class ReportWarningFlagTests: XCTestCase {
    private func report(_ entries: [ReportEntry]) -> ProcessingReport {
        ProcessingReport(summary: RunSummary(startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1),
                                             outputMode: "x", total: entries.count, succeeded: entries.count, failed: 0,
                                             inputBytes: 1, outputBytes: 1), entries: entries)
    }

    func testTheFlagIsStructuredNotReadFromTheNote() {
        let spoof = ReportEntry(source: "/a.jpg", status: .succeeded, inputBytes: 1, note: "Image analysis unavailable: x")
        XCTAssertFalse(spoof.warning, "a note template can say anything")
        var flagged = ReportEntry(source: "/a.jpg", status: .succeeded, inputBytes: 1, note: "anything")
        flagged.warning = true
        XCTAssertTrue(flagged.warning)
    }

    func testOldReportsDecodeWithoutTheFlag() throws {
        let old = Data(#"{"source":"/a.jpg","status":"succeeded","inputBytes":1,"duration":0}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ReportEntry.self, from: old).warning)
        var entry = ReportEntry(source: "/a.jpg", status: .succeeded, inputBytes: 1)
        entry.warning = true
        XCTAssertTrue(try JSONDecoder().decode(ReportEntry.self, from: JSONEncoder().encode(entry)).warning)
    }

    func testExportsCarryTheFlag() {
        var warned = ReportEntry(source: "/a.jpg", destination: "/o/a.jpg", status: .succeeded, inputBytes: 1, outputBytes: 1)
        warned.warning = true
        let plain = ReportEntry(source: "/b.jpg", destination: "/o/b.jpg", status: .succeeded, inputBytes: 1, outputBytes: 1)
        let both = report([warned, plain])
        let json = String(bytes: ReportExporter.json(both), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""warning" : true"#), json)
        XCTAssertEqual(json.components(separatedBy: #""warning""#).count, 2, "only the flagged row says so")
        let csv = ReportExporter.csv(both).components(separatedBy: "\r\n")
        XCTAssertTrue(csv[0].hasSuffix(#","warning""#))
        XCTAssertTrue(csv[1].hasSuffix(#","true""#))
        XCTAssertTrue(csv[2].hasSuffix(#","false""#))
        let text = ReportExporter.text(both)
        XCTAssertTrue(text.contains("succeeded (warning): /a.jpg"))
        XCTAssertTrue(text.contains("succeeded: /b.jpg"))
        XCTAssertTrue(ReportExporter.html(both).contains("<td class=\"status warning\">warning</td>"))
    }

    func testTheFlagTravelsFromTheBatchToTheReport() {
        var written = WrittenItem(url: URL(fileURLWithPath: "/o/a.jpg"), note: "n", inputBytes: 1, outputBytes: 1)
        written.warning = true
        let plan = PlannedOutput(item: InputItem(source: URL(fileURLWithPath: "/a.jpg"), relativeDirectory: ""),
                                 destination: URL(fileURLWithPath: "/o/a.jpg"), replacesSource: false,
                                 trashesSource: false)
        let batch = BatchRunner.makeReport(plans: [plan], outcomes: [.success(written)], inputSizes: [1], cancelled: false)
        XCTAssertEqual(batch.entries.first?.warning, true)
        XCTAssertEqual(ProcessingReport(batch: batch, total: 1, outputMode: "x").entries.first?.warning, true)
    }

    func testAFailedConditionAnalysisIsAWarning() {
        let shows = ConditionalStep(conditions: [Condition(.containsText(true))], then: [.skip])
        let pipeline = Pipeline(steps: [PipelineStep(operation: .condition(shows))])
        var facts = ItemFacts(width: 10, height: 10)
        facts.analysis = ImageAnalysis(failure: "Vision broke")
        XCTAssertTrue(pipeline.resolved(for: facts).warning)
        facts.analysis = ImageAnalysis(hasText: false)
        XCTAssertFalse(pipeline.resolved(for: facts).warning)
    }
}

final class RedactTextDefaultsTests: XCTestCase {
    func testTextDefaultsToSolidColour() {
        XCTAssertEqual(RedactOptions(target: .faces).style, .blur)
        XCTAssertEqual(RedactOptions(target: .text).style, .fill)
        XCTAssertEqual(RedactOptions(target: .both).style, .fill)
        XCTAssertEqual(RedactOptions(target: .text).fillColor, .black)
        XCTAssertEqual(StepKind.redact.defaultOperation, .redact(RedactOptions(target: .faces, style: .blur)))
        // Saved steps keep their style.
        let saved = Data(#"{"target":"text","style":"blur"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RedactOptions.self, from: saved).style, .blur)
    }

    func testChangingTheTargetFollowsTheDefaultUnlessAStyleWasChosen() {
        XCTAssertEqual(RedactOptions(target: .faces).retargeted(.both).style, .fill)
        XCTAssertEqual(RedactOptions(target: .both).retargeted(.faces).style, .blur)
        XCTAssertEqual(RedactOptions(target: .faces, style: .pixelate).retargeted(.text).style, .pixelate)
        XCTAssertEqual(RedactOptions(target: .faces).retargeted(.text).target, .text)
    }

    func testThePrivacySuggestionHidesTextWithAFill() {
        var empty = Pipeline()
        empty.addRedaction(.text)
        XCTAssertEqual(empty.steps.map(\.operation), [.redact(RedactOptions(target: .text, style: .fill))])

        // A blurring faces step isn't widened to text: a separate fill step is added after it.
        var blurring = Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions(target: .faces)))])
        blurring.addRedaction(.text)
        XCTAssertEqual(blurring.steps.map(\.operation),
                       [.redact(RedactOptions(target: .faces)), .redact(RedactOptions(target: .text, style: .fill))])
        blurring.addRedaction(.text)
        XCTAssertEqual(blurring.steps.count, 2, "text is covered now")

        // A filling step is widened.
        var filling = Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions(target: .faces, style: .fill)))])
        filling.addRedaction(.text)
        XCTAssertEqual(filling.steps.map(\.operation), [.redact(RedactOptions(target: .both, style: .fill))])
        filling.addRedaction(.faces)
        XCTAssertEqual(filling.steps.count, 1)
    }

    func testWordingWarnsAboutReversibleText() {
        let advice = "For text, use Solid colour: blur and pixelation can sometimes be reversed."
        XCTAssertEqual(Redaction.textAdvice, advice)
        XCTAssertTrue((StepHelp.info(for: .redact).howTo + StepHelp.info(for: .redact).tips).contains(advice))
    }
}

final class RedactDetectionQualityTests: XCTestCase {
    func testFacesUseTheLargerCopyToo() {
        let detector = FakeVisionDetector()
        _ = Redaction.detect(.faces, in: TestImages.make(width: 3000, height: 1000), detector: detector)
        XCTAssertEqual(detector.recorded.map(\.kind), ["faces"])
        XCTAssertEqual(detector.recorded.first?.width, 2048)
        XCTAssertEqual(detector.faceSides, [2048])
    }

    func testEveryTextBoxIsKeptAndOnlyTheCountIsDeduplicated() {
        let line = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1)
        let sameLine = CGRect(x: 0.11, y: 0.1, width: 0.48, height: 0.1)
        let handwriting = CGRect(x: 0.2, y: 0.6, width: 0.3, height: 0.2)
        XCTAssertEqual(TextBoxes.combined(recognized: [line], rectangles: [sameLine, handwriting]),
                       [line, sameLine, handwriting])
        XCTAssertEqual(TextBoxes.distinctCount([line, sameLine, handwriting]), 2)
        XCTAssertEqual(TextBoxes.distinctCount([]), 0)
    }

    func testAWideTextRectangleAroundASmallerLineIsRedactedWhole() throws {
        let line = CGRect(x: 0.2, y: 0.4, width: 0.3, height: 0.1)
        let rectangle = CGRect(x: 0.1, y: 0.35, width: 0.7, height: 0.2)
        let detector = FakeVisionDetector(text: TextBoxes.combined(recognized: [line], rectangles: [rectangle]))
        let fill = RedactOptions(target: .text, style: .fill, fillColor: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
                                 padding: 0)
        var notes: [String] = []
        let out = try Pipeline(steps: [PipelineStep(operation: .redact(fill))])
            .apply(to: TestImages.make(width: 100, height: 100), focus: FocusContext(detector: detector), notes: &notes)
        for row in 35..<55 {
            for col in 10..<80 {
                let pixel = TestImages.pixel(of: out, x: col, y: row)
                if !(pixel.green > 250 && pixel.red < 5) { return XCTFail("(\(col), \(row)) not redacted") }
            }
        }
        XCTAssertGreaterThan(TestImages.pixel(of: out, x: 90, y: 45).red, 150, "outside the rectangle untouched")
        XCTAssertEqual(notes, ["Redacted 1 text area"])
    }

    func testContentCheckReportsFailuresAndUsesTheRedactResolution() throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 3000, height: 1500), to: url, type: .png)
        let detector = FakeVisionDetector(faces: [CGRect(x: 0, y: 0, width: 0.1, height: 0.1)])
        XCTAssertEqual(ContentCheck.run(url, detector: detector), .found(ContentFindings(faceCount: 1, hasText: false)))
        XCTAssertEqual(detector.recorded.first?.width, 2048, "same resolution as Redact")
        guard case .failed(let reason) = ContentCheck.run(url, detector: FakeVisionDetector(error: VisionBroke())) else {
            return XCTFail("a failed check must say so")
        }
        XCTAssertEqual(reason, "Vision broke")
        let lines = ContentPrivacySummary.lines([.found(ContentFindings(faceCount: 1)), .failed("Vision broke"),
                                                 .failed("other")])
        XCTAssertEqual(lines.map(\.text), ["1 image shows faces", "Couldn't check 2 images: Vision broke"])
        XCTAssertEqual(lines.map(\.target), [.faces, nil])
    }
}

final class RedactFaceRegionTests: XCTestCase {
    private static let xmp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"
     xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"
     xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#"
     xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/">
    <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Kept title</rdf:li></rdf:Alt></dc:title>
    <mwg-rs:Regions rdf:parseType="Resource"><mwg-rs:RegionList><rdf:Bag><rdf:li rdf:parseType="Resource">
    <mwg-rs:Name>Alice</mwg-rs:Name><mwg-rs:Type>Face</mwg-rs:Type>
    <mwg-rs:Area stArea:x="0.5" stArea:y="0.5" stArea:w="0.2" stArea:h="0.2" stArea:unit="normalized"/>
    </rdf:li></rdf:Bag></mwg-rs:RegionList></mwg-rs:Regions>
    <Iptc4xmpExt:PersonInImage><rdf:Bag><rdf:li>Alice</rdf:li></rdf:Bag></Iptc4xmpExt:PersonInImage>
    </rdf:Description></rdf:RDF></x:xmpmeta>
    """

    private func source(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("people.jpg")
        let meta = try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(Self.xmp.utf8) as CFData))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(dest, TestImages.make(width: 40, height: 40), meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func tag(_ path: String, in data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return false }
        return CGImageMetadataCopyTagWithPath(meta, nil, path as CFString) != nil
    }

    private func encode(_ url: URL, target: RedactTarget, metadataOn: Bool) throws -> EncodedItem {
        var pipeline = Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions(target: target)))],
                                output: OutputSettings(format: .jpeg))
        if metadataOn { pipeline.metadata = MetadataOptions(isEnabled: true, removeLocation: true) }
        var options = ItemRunOptions()
        options.focus = FocusContext(detector: FakeVisionDetector())
        return try BatchRunner.encodeItem(url, pipeline: pipeline, assets: .empty,
                                          maxPixels: ImageLoader.defaultMaxPixels, options: options)
    }

    func testFaceRegionsAreRemovedWhenFacesAreRedacted() throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try source(in: dir)
        XCTAssertTrue(tag("mwg-rs:Regions", in: try Data(contentsOf: url)), "fixture carries regions")

        let redacted = try encode(url, target: .faces, metadataOn: true)
        XCTAssertFalse(tag("mwg-rs:Regions", in: redacted.data))
        XCTAssertFalse(tag("Iptc4xmpExt:PersonInImage", in: redacted.data))
        XCTAssertTrue(tag("dc:title", in: redacted.data), "other XMP stays")
        XCTAssertTrue(redacted.note?.contains(Redaction.faceRegionsRemovedNote) == true, redacted.note ?? "")

        let textOnly = try encode(url, target: .text, metadataOn: true)
        XCTAssertTrue(tag("mwg-rs:Regions", in: textOnly.data), "text redaction leaves face regions alone")
        XCTAssertFalse(textOnly.note?.contains(Redaction.faceRegionsRemovedNote) == true)

        // Without the Metadata step no source XMP is written at all, so there is nothing to remove or say.
        let plain = try encode(url, target: .faces, metadataOn: false)
        XCTAssertFalse(tag("mwg-rs:Regions", in: plain.data))
        XCTAssertFalse(plain.note?.contains(Redaction.faceRegionsRemovedNote) == true)
    }
}

final class RedactOrderAndFormatTests: XCTestCase {
    func testANewRedactStepGoesBeforeAnyWatermark() {
        let watermarkFirst = Pipeline(steps: [PipelineStep(operation: .watermark(WatermarkOptions())),
                                              PipelineStep(operation: .crop(CropOptions()))])
        XCTAssertEqual(watermarkFirst.redactInsertionIndex, 0)
        let usual = Pipeline(steps: [PipelineStep(operation: .crop(CropOptions())),
                                     PipelineStep(operation: .watermark(WatermarkOptions()))])
        XCTAssertEqual(usual.redactInsertionIndex, 1)
    }

    /// An image with alpha (premultiplied RGBA, transparent left half) or 16 bits: outside identical, alpha kept.
    private func assertOutsideIdentical(_ image: CGImage, style: RedactStyle) throws {
        let box = CGRect(x: 10, y: 10, width: 20, height: 20)
        let out = try ImageOps.redact(image, RedactOptions(style: style), rects: [box])
        XCTAssertEqual(out.bitsPerComponent, image.bitsPerComponent)
        XCTAssertEqual(out.alphaInfo, image.alphaInfo)
        let before = [UInt8](try XCTUnwrap(image.dataProvider?.data as Data?))
        let after = [UInt8](try XCTUnwrap(out.dataProvider?.data as Data?))
        let pixelBytes = image.bitsPerPixel / 8
        for row in 0..<image.height {
            for col in 0..<image.width where !box.contains(CGPoint(x: Double(col) + 0.5, y: Double(row) + 0.5)) {
                let start = row * image.bytesPerRow + col * pixelBytes
                let range = start..<(start + pixelBytes)
                let outStart = row * out.bytesPerRow + col * pixelBytes
                XCTAssertEqual(Array(before[range]), Array(after[outStart..<(outStart + pixelBytes)]),
                               "(\(col), \(row))")
                if before[range] != after[outStart..<(outStart + pixelBytes)] { return }
            }
        }
    }

    func testAlphaImagesKeepTheirPixelsAndAlpha() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
        let image = try XCTUnwrap(ctx.makeImage())
        for style in RedactStyle.allCases { try assertOutsideIdentical(image, style: style) }
    }

    func testSixteenBitImagesKeepTheirPixels() throws {
        for style in RedactStyle.allCases { try assertOutsideIdentical(TestImages.displayP3(width: 40, height: 40), style: style) }
    }
}
