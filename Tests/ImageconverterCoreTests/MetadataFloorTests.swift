import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// The Metadata step's removals are a floor no condition can lower (final review C1).
final class MetadataFloorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let gps: [String: Any] = [kCGImagePropertyGPSDictionary as String: [
        kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
        kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E"
    ] as [String: Any]]

    private func located(_ name: String = "located.jpg", type: UTType = .jpeg) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: type, properties: gps)
        return url
    }

    private func pipeline(global: MetadataOptions, branch: [ConditionalAction]) -> Pipeline {
        let condition = ConditionalStep(conditions: [.hasGPS(true)], then: branch)
        return Pipeline(steps: [PipelineStep(operation: .condition(condition))], output: OutputSettings(format: .jpeg),
                        metadata: global)
    }

    private func hasGPS(_ url: URL) throws -> Bool {
        try TestImages.properties(of: Data(contentsOf: url))[kCGImagePropertyGPSDictionary as String] != nil
    }

    private var strip: MetadataOptions { MetadataOptions(isEnabled: true, location: .remove) }

    // MARK: merging

    func testOverrideKeepsGlobalRemovals() {
        var global = MetadataOptions(isEnabled: true, removeAll: true, location: .remove, removeCamera: true)
        global.keepWhenRemovingAll = [.copyright, .location]
        global.removeXMP = true
        var override = MetadataOptions(location: .keep, artist: "Studio")
        override.keepWhenRemovingAll = [.cameraInfo]
        let merged = override.withRemovals(from: global)
        XCTAssertTrue(merged.removeAll)
        XCTAssertEqual(merged.location, .remove)
        XCTAssertTrue(merged.removeCamera)
        XCTAssertTrue(merged.removeXMP)
        XCTAssertEqual(merged.artist, "Studio", "fields the override sets stay")
        XCTAssertEqual(merged.keepWhenRemovingAll, [.copyright], "location is removed by the floor")
    }

    func testOverrideMayAddRemovalsAndReplaceLocation() {
        let global = MetadataOptions(isEnabled: true, location: .remove)
        let replaced = MetadataOptions(location: .set(latitude: 1, longitude: 2, altitude: nil), removeCamera: true)
            .withRemovals(from: global)
        XCTAssertEqual(replaced.location, .set(latitude: 1, longitude: 2, altitude: nil))
        XCTAssertTrue(replaced.removeCamera)
    }

    func testInactiveGlobalStepIsNoFloor() {
        let off = MetadataOptions(isEnabled: false, location: .remove)
        let override = MetadataOptions(location: .keep)
        XCTAssertEqual(override.withRemovals(from: off), override)
    }

    func testBothRemoveAllKeepOnlyWhatBothKeep() {
        var global = MetadataOptions(isEnabled: true, removeAll: true)
        global.keepWhenRemovingAll = [.copyright, .dateTaken]
        var override = MetadataOptions(removeAll: true)
        override.keepWhenRemovingAll = [.copyright, .location]
        XCTAssertEqual(override.withRemovals(from: global).keepWhenRemovingAll, [.copyright])
    }

    // MARK: batch

    func testConditionMetadataWithoutStripStillRemovesGPS() async throws {
        let source = try located()
        let run = pipeline(global: strip, branch: [.metadata(MetadataOptions(location: .keep, artist: "A"))])
        let report = await BatchRunner.run([InputItem(source: source, relativeDirectory: "")], pipeline: run,
                                           mode: .newFolder(root.appendingPathComponent("out")))
        XCTAssertEqual(report.failures, [])
        XCTAssertFalse(try hasGPS(XCTUnwrap(report.written.first)))
    }

    func testCopyOriginalIsConvertedWhenRemovalsAreActive() async throws {
        let source = try located()
        let run = pipeline(global: strip, branch: [.copyOriginal])
        let resolved = run.resolved(forSource: source)
        XCTAssertEqual(resolved.disposition, .process)
        XCTAssertEqual(resolved.pipeline.output.format, .jpeg)
        XCTAssertEqual(resolved.pipeline.output.quality, 1)
        XCTAssertEqual(resolved.statusNote, ConditionalStep.convertedForPrivacyNote)
        let report = await BatchRunner.run([InputItem(source: source, relativeDirectory: "")], pipeline: run,
                                           mode: .newFolder(root.appendingPathComponent("out")))
        XCTAssertEqual(report.failures, [])
        let written = try XCTUnwrap(report.written.first)
        XCTAssertEqual(written.lastPathComponent, "located.jpg")
        XCTAssertFalse(try hasGPS(written))
        XCTAssertEqual(report.notes.first?.text, ConditionalStep.convertedForPrivacyNote)
    }

    func testCopyOfPNGIsConvertedLosslessly() throws {
        let source = try located("located.png", type: .png)
        let resolved = pipeline(global: strip, branch: [.copyOriginal]).resolved(forSource: source)
        XCTAssertEqual(resolved.pipeline.output.format, .png)
        XCTAssertTrue(resolved.pipeline.steps.isEmpty)
    }

    func testCopyOriginalStaysACopyWithoutRemovals() throws {
        let source = try located()
        let resolved = pipeline(global: MetadataOptions(isEnabled: true, location: .keep, artist: "A"),
                                branch: [.copyOriginal]).resolved(forSource: source)
        XCTAssertEqual(resolved.disposition, .copyOriginal)
        XCTAssertNil(resolved.notes.first)
    }

    /// Re-review N1: a floor that removes the location also removes the place names when an override only
    /// replaces the coordinates.
    func testSetLocationOverrideStillDropsPlaceNamesUnderAStripFloor() async throws {
        let url = root.appendingPathComponent("city.jpg")
        var properties = gps
        properties[kCGImagePropertyIPTCDictionary as String] = [
            kCGImagePropertyIPTCCity as String: "Stockholm", kCGImagePropertyIPTCCountryPrimaryLocationName as String: "Sweden"
        ]
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .jpeg, properties: properties)
        let replace = MetadataOptions(location: .set(latitude: 1, longitude: 2, altitude: nil))
        let merged = replace.withRemovals(from: strip)
        XCTAssertTrue(merged.removePlaceNames)
        XCTAssertFalse(replace.withRemovals(from: MetadataOptions(isEnabled: true, location: .keep)).removePlaceNames)
        let report = await BatchRunner.run([InputItem(source: url, relativeDirectory: "")],
                                           pipeline: pipeline(global: strip, branch: [.metadata(replace)]),
                                           mode: .newFolder(root.appendingPathComponent("out")))
        XCTAssertEqual(report.failures, [])
        let data = try Data(contentsOf: XCTUnwrap(report.written.first))
        let written = try TestImages.properties(of: data)
        let iptc = written[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(iptc[kCGImagePropertyIPTCCity as String], "the real city must not survive")
        XCTAssertNil(iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String])
        let position = try XCTUnwrap(written[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        XCTAssertEqual(position[kCGImagePropertyGPSLatitude as String] as? Double, 1)
        let xmp = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(
            XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), 0, nil))
        XCTAssertNil(CGImageMetadataCopyStringValueWithPath(xmp, nil, "photoshop:City" as CFString))
    }

    /// Re-review N1 (date): a floor that sets the date wins over an override that only shifts it (a shift of the
    /// real date would reveal it).
    func testFloorSetDateWinsOverOverrideShift() {
        var floor = MetadataOptions(isEnabled: true, location: .keep)
        floor.dateTaken = .set(Date(timeIntervalSince1970: 0))
        var override = MetadataOptions(location: .keep)
        override.dateTaken = .shift(seconds: 60)
        XCTAssertEqual(override.withRemovals(from: floor).dateTaken, .set(Date(timeIntervalSince1970: 0)))
        override.dateTaken = .set(Date(timeIntervalSince1970: 99))
        XCTAssertEqual(override.withRemovals(from: floor).dateTaken, .set(Date(timeIntervalSince1970: 99)))
    }

    // MARK: invalid saved date

    func testInvalidSavedDateIsFlaggedAndReported() async throws {
        let json = #"{"isEnabled":true,"isIncluded":true,"location":{"mode":"keep"},"dateTaken":{"mode":"set","date":1e300}}"#
        let options = try JSONDecoder().decode(MetadataOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.dateTaken, .keep)
        XCTAssertTrue(options.dateTakenWasInvalid)
        var edited = options
        edited.dateTaken = .shift(seconds: 60)
        XCTAssertFalse(edited.dateTakenWasInvalid, "an edit replaces the invalid setting")
        let valid = try JSONDecoder().decode(MetadataOptions.self, from: JSONEncoder().encode(MetadataOptions()))
        XCTAssertFalse(valid.dateTakenWasInvalid)

        let source = try located()
        let run = Pipeline(output: OutputSettings(format: .jpeg), metadata: options)
        let report = await BatchRunner.run([InputItem(source: source, relativeDirectory: "")], pipeline: run,
                                           mode: .newFolder(root.appendingPathComponent("out")))
        XCTAssertEqual(report.notes.first?.text, MetadataOptions.invalidDateNote)
    }
}
