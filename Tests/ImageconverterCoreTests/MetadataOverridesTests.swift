import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// The metadata panel's per-image overrides: the model, precedence over the Metadata step, every write path
/// (re-encode, lossless copy, extra outputs, converted copies) and that the original is never touched.
final class MetadataOverridesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let gps = kCGImagePropertyGPSDictionary as String
    private let tiff = kCGImagePropertyTIFFDictionary as String
    private let exif = kCGImagePropertyExifDictionary as String
    private let iptc = kCGImagePropertyIPTCDictionary as String

    private var richProps: [String: Any] {
        [tiff: [kCGImagePropertyTIFFMake as String: "MAKEX", kCGImagePropertyTIFFArtist as String: "ARTISTX"],
         exif: [kCGImagePropertyExifDateTimeOriginal as String: "2020:01:02 03:04:05",
                kCGImagePropertyExifBodySerialNumber as String: "SERIALX",
                kCGImagePropertyExifLensSerialNumber as String: "LENSSERIALX"],
         iptc: [kCGImagePropertyIPTCCity as String: "CITYX", kCGImagePropertyIPTCObjectName as String: "OLDTITLE"],
         gps: [kCGImagePropertyGPSLatitude as String: 59.3293, kCGImagePropertyGPSLatitudeRef as String: "N",
               kCGImagePropertyGPSLongitude as String: 18.0686, kCGImagePropertyGPSLongitudeRef as String: "E"]]
    }

    private func photo(_ name: String = "meadow.jpg") throws -> URL {
        try MetadataTestSupport.source(root.appendingPathComponent(name), properties: richProps)
    }

    private func item(_ url: URL, _ overrides: MetadataOverrides) -> InputItem {
        var item = InputItem(source: url, relativeDirectory: "")
        item.metadataOverrides = overrides
        return item
    }

    private func run(_ items: [InputItem], pipeline: Pipeline) async throws -> BatchReport {
        let out = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        let report = await BatchRunner.run(items, pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.failures, [])
        return report
    }

    // MARK: Model

    func testSetValidatesAndRemovalFollowsTheField() {
        var overrides = MetadataOverrides()
        XCTAssertFalse(overrides.set(.title, to: .text("  \u{0007} ")))
        XCTAssertFalse(overrides.set(.location, to: .location(latitude: 91, longitude: 0, altitude: nil)))
        XCTAssertFalse(overrides.set(.rating, to: .rating(6)))
        XCTAssertFalse(overrides.set(.custom(.exif, "MakerNote"), to: .text("x")))
        XCTAssertTrue(overrides.isEmpty)
        XCTAssertTrue(overrides.set(.title, to: .text("New\u{0000} title")))
        XCTAssertEqual(overrides.fields[.title], .text("New title"))

        // Removing any place of an editable field removes the field; another path is removed on its own.
        let byline = MetadataPath.property(dictionary: iptc, key: kCGImagePropertyIPTCByline as String)
        let lensSerial = MetadataPath.property(dictionary: exif, key: kCGImagePropertyExifLensSerialNumber as String)
        overrides.remove(byline)
        overrides.remove(lensSerial)
        XCTAssertEqual(overrides.fields[.creator], .removed)
        XCTAssertTrue(overrides.isRemoved(.xmp("dc:creator")))
        XCTAssertTrue(overrides.isRemoved(lensSerial))
        XCTAssertEqual(overrides.count, 3)
        overrides.revert(.xmp("dc:creator"))
        overrides.revert(lensSerial)
        XCTAssertFalse(overrides.isChanged(byline))
        XCTAssertEqual(overrides.count, 1)
    }

    func testItemsStayEqualWhateverTheirOverrides() throws {
        let url = try photo()
        var edits = MetadataOverrides()
        edits.set(.title, to: .text("T"))
        XCTAssertEqual(item(url, edits), InputItem(source: url, relativeDirectory: ""))
        XCTAssertEqual(Set([item(url, edits), InputItem(source: url, relativeDirectory: "")]).count, 1)
    }

    // MARK: Batch

    func testStepOffOverridesStillApplyAndTheOriginalIsUntouched() async throws {
        let url = try photo()
        let before = try Data(contentsOf: url)
        var edits = MetadataOverrides()
        edits.set(.title, to: .text("NEWTITLE"))
        edits.remove(.dictionary(gps))
        edits.remove(.property(dictionary: exif, key: kCGImagePropertyExifLensSerialNumber as String))
        // A re-encode: PNG output, so the lossless copy doesn't apply.
        let report = try await run([item(url, edits)], pipeline: Pipeline(output: OutputSettings(format: .png)))
        let written = try WrittenFile(url: try XCTUnwrap(report.written.first))
        XCTAssertEqual(written.xmp("dc:title"), "NEWTITLE")
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertFalse(written.contains("LENSSERIALX"))
        // Everything else is kept as it was: the step is off.
        XCTAssertTrue(written.contains("SERIALX"))
        XCTAssertEqual(try Data(contentsOf: url), before, "the original must never change")
    }

    func testAnItemWithoutOverridesIsUnaffected() async throws {
        let edited = try photo("a.jpg")
        let plain = try photo("b.jpg")
        var edits = MetadataOverrides()
        edits.remove(.dictionary(gps))
        let report = try await run([item(edited, edits), InputItem(source: plain, relativeDirectory: "")],
                                   pipeline: Pipeline(output: OutputSettings(format: .png)))
        let outputs = try report.written.map { try WrittenFile(url: $0) }
        XCTAssertNil(outputs.first { $0.url.lastPathComponent.hasPrefix("a") }?.sub(kCGImagePropertyGPSDictionary))
        XCTAssertNotNil(outputs.first { $0.url.lastPathComponent.hasPrefix("b") }?.sub(kCGImagePropertyGPSDictionary))
    }

    func testSetWinsOverTheStepAndTheFloorStillRemovesTheRest() async throws {
        let url = try photo()
        var edits = MetadataOverrides()
        edits.set(.copyright, to: .text("COPYX"))
        var step = MetadataOptions(isEnabled: true, removeAll: true)
        step.keepWhenRemovingAll = []
        let report = try await run([item(url, edits)],
                                   pipeline: Pipeline(output: OutputSettings(format: .png), metadata: step))
        let written = try WrittenFile(url: try XCTUnwrap(report.written.first))
        XCTAssertEqual(written.xmp("dc:rights"), "COPYX")
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertFalse(written.contains("SERIALX"))
        XCTAssertFalse(written.contains("ARTISTX"))
    }

    func testRemovalWinsOverAFieldTheStepSets() async throws {
        let url = try photo()
        var edits = MetadataOverrides()
        edits.remove(.property(dictionary: tiff, key: kCGImagePropertyTIFFArtist as String))
        let step = MetadataOptions(isEnabled: true, removeLocation: false, artist: "STEPARTIST")
        let report = try await run([item(url, edits)],
                                   pipeline: Pipeline(output: OutputSettings(format: .png), metadata: step))
        let written = try WrittenFile(url: try XCTUnwrap(report.written.first))
        XCTAssertFalse(written.contains("STEPARTIST"))
        XCTAssertFalse(written.contains("ARTISTX"))
        XCTAssertNil(written.xmp("dc:creator"))
    }

    func testSetPositionKeepsTheStepsPlaceNameRemoval() async throws {
        let url = try photo()
        var edits = MetadataOverrides()
        edits.set(.location, to: .location(latitude: -33.5, longitude: 151.25, altitude: nil))
        let step = MetadataOptions(isEnabled: true, removeLocation: true)
        let report = try await run([item(url, edits)],
                                   pipeline: Pipeline(output: OutputSettings(format: .png), metadata: step))
        let written = try WrittenFile(url: try XCTUnwrap(report.written.first))
        let position = try XCTUnwrap(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertEqual(position[kCGImagePropertyGPSLatitudeRef as String] as? String, "S")
        XCTAssertEqual((position[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue ?? 0, 151.25,
                       accuracy: 1e-4)
        XCTAssertFalse(written.contains("CITYX"))
    }

    func testLosslessCopyCarriesAndVerifiesTheOverrides() async throws {
        let url = try photo()
        var edits = MetadataOverrides()
        edits.set(.title, to: .text("LOSSLESSTITLE"))
        edits.set(.rating, to: .rating(4))
        edits.remove(.dictionary(gps))
        let report = try await run([item(url, edits)], pipeline: Pipeline(output: OutputSettings(format: .jpeg)))
        XCTAssertTrue(report.notes.contains { $0.text.contains(LosslessMetadata.pixelsUntouchedNote) },
                      "\(report.notes)")
        let written = try WrittenFile(url: try XCTUnwrap(report.written.first))
        XCTAssertEqual(written.xmp("dc:title"), "LOSSLESSTITLE")
        XCTAssertEqual(written.xmp("xmp:Rating"), "4")
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
    }

    func testExtraOutputsGetTheOverridesToo() async throws {
        let url = try photo()
        var edits = MetadataOverrides()
        edits.set(.creator, to: .text("EXTRACREATOR"))
        let pipeline = Pipeline(output: OutputSettings(format: .png), extraOutputs: [
            OutputVariant(name: "Small", settings: OutputSettings(format: .jpeg), resize: .percent(50), nameSuffix: "_s"),
        ])
        let report = try await run([item(url, edits)], pipeline: pipeline)
        XCTAssertEqual(report.written.count, 2)
        for output in report.written {
            XCTAssertEqual(try WrittenFile(url: output).xmp("dc:creator"), "EXTRACREATOR", output.lastPathComponent)
        }
    }

    func testCopiedOriginalIsConvertedToApplyTheOverrides() async throws {
        let url = try photo()
        var edits = MetadataOverrides()
        edits.remove(.dictionary(gps))
        let conditional = ConditionalStep(conditions: [.width(.atLeast, 0)], then: [.copyOriginal])
        let pipeline = Pipeline(steps: [PipelineStep(operation: .condition(conditional))])
        let report = try await run([item(url, edits)], pipeline: pipeline)
        let written = try WrittenFile(url: try XCTUnwrap(report.written.first))
        XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertTrue(report.notes.contains { $0.text.contains(ConditionalStep.convertedForMetadataEditsNote) })
    }

    func testEstimateUsesTheOverrides() throws {
        let url = try photo()
        var edits = MetadataOverrides()
        edits.remove(.dictionary(gps))
        let estimate = try SizeEstimator.render(item: item(url, edits), pipeline: Pipeline(output: OutputSettings(format: .png)))
        XCTAssertFalse(try XCTUnwrap(estimate.privacy).findings.contains { $0.kind == .location })
        let plain = try SizeEstimator.render(item: InputItem(source: url, relativeDirectory: ""),
                                             pipeline: Pipeline(output: OutputSettings(format: .png)))
        XCTAssertTrue(try XCTUnwrap(plain.privacy).findings.contains { $0.kind == .location })
    }

    // MARK: Inspection and privacy values

    func testInspectionGroupsValuesHeaderOnly() throws {
        let url = try MetadataTestSupport.source(root.appendingPathComponent("x.jpg"), properties: richProps,
                                                 xmp: [("xmpRights:UsageTerms", "TERMSX")])
        let inspection = MetadataInspection.read(url)
        XCTAssertNil(inspection.failure)
        let position = try XCTUnwrap(inspection.entry(for: .dictionary(gps)))
        XCTAssertEqual(position.group, .location)
        XCTAssertEqual(position.value, "59.3293° N, 18.0686° E")
        XCTAssertEqual(position.field, .location)
        let serial = try XCTUnwrap(inspection.entry(for: .property(dictionary: exif, key: "BodySerialNumber")))
        XCTAssertEqual(serial.group, .camera)
        XCTAssertEqual(serial.field, .custom(.exif, "BodySerialNumber"))
        let lens = try XCTUnwrap(inspection.entry(for: .property(dictionary: exif, key: "LensSerialNumber")))
        XCTAssertNil(lens.field)
        XCTAssertTrue(lens.removable)
        XCTAssertEqual(inspection.entries.filter { $0.value == "TERMSX" }.map(\.group), [.rights])
        XCTAssertTrue(inspection.entries.contains { $0.group == .file && $0.value == "x.jpg" })
        // Fields already present aren't offered again; the rest are.
        XCTAssertFalse(inspection.addableFields.contains(.location))
        XCTAssertTrue(inspection.addableFields.contains(.rating))
        XCTAssertEqual(inspection.entries(in: .camera, matching: "lensserial").map(\.id), [lens.id])
    }

    func testDisplayEscapesInvisibleAndBidiCharacters() {
        XCTAssertEqual(MetadataInspection.display("a\u{202E}b\nc"), "a<U+202E>b<U+000A>c")
        XCTAssertEqual(MetadataInspection.display(String(repeating: "x", count: 30), limit: 10), "xxxxxxxxxx…")
    }

    func testPrivacyFindingsCarryValuesAndPaths() throws {
        let url = try photo()
        let findings = PrivacyScanner.scan(url).findings
        let location = try XCTUnwrap(findings.first { $0.kind == .location })
        XCTAssertEqual(location.details.first?.value, "59.3293° N, 18.0686° E")
        XCTAssertEqual(location.details.first?.path, .dictionary(gps))
        let serials = try XCTUnwrap(findings.first { $0.kind == .serialNumbers })
        XCTAssertTrue(serials.details.contains {
            $0.value == "SERIALX" && $0.path == .property(dictionary: exif, key: "BodySerialNumber")
        })
        let owner = try XCTUnwrap(findings.first { $0.kind == .owner })
        XCTAssertEqual(owner.details.first?.value, "ARTISTX")
        XCTAssertEqual(owner.fields.first, "Artist")
    }

    func testPrivacyValuesAreEscapedAndShortened() throws {
        let long = "\u{202E}" + String(repeating: "N", count: 400)
        let url = try MetadataTestSupport.source(root.appendingPathComponent("long.jpg"),
                                                 properties: [tiff: [kCGImagePropertyTIFFArtist as String: long]])
        let owner = try XCTUnwrap(PrivacyScanner.scan(url).findings.first { $0.kind == .owner })
        let value = try XCTUnwrap(owner.details.first?.value)
        XCTAssertTrue(value.hasPrefix("<U+202E>"))
        XCTAssertLessThanOrEqual(value.count, PrivacyDetail.maxLength + 1)
    }
}

/// The panel lists an IPTC field once, not again as ImageIO's XMP twin; removing it removes both.
final class MetadataInspectionTwinTests: XCTestCase {
    func testIPTCTwinIsListedOnceAndRemovedWithTheField() async throws {
        let root = try TestImages.tempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let iptc = kCGImagePropertyIPTCDictionary as String
        let url = try MetadataTestSupport.source(root.appendingPathComponent("c.jpg"),
                                                 properties: [iptc: [kCGImagePropertyIPTCCity as String: "CITYX"]])
        let entries = MetadataInspection.read(url).entries.filter { $0.value == "CITYX" }
        XCTAssertEqual(entries.map(\.id), ["{IPTC}.City"])
        var item = InputItem(source: url, relativeDirectory: "")
        item.metadataOverrides.remove(.property(dictionary: iptc, key: kCGImagePropertyIPTCCity as String))
        let report = await BatchRunner.run([item], pipeline: Pipeline(output: OutputSettings(format: .png)),
                                           mode: .newFolder(root.appendingPathComponent("out", isDirectory: true)))
        XCTAssertFalse(try WrittenFile(url: try XCTUnwrap(report.written.first)).contains("CITYX"))
    }
}
