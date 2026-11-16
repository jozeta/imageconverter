import ImageIO
import XCTest
@testable import ImageconverterCore

/// Fix round 1: a run interrupted and resumed keeps each image's metadata panel changes (stored in the journal).
final class MetadataOverridesResumeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let gps = kCGImagePropertyGPSDictionary as String

    private func photo(_ name: String) throws -> URL {
        try MetadataTestSupport.source(root.appendingPathComponent(name), properties: [gps: [
            kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E",
        ] as [String: Any]])
    }

    func testResumedRunKeepsAGPSRemoval() async throws {
        let urls = try [photo("a.jpg"), photo("b.jpg"), photo("c.jpg")]
        var edits = MetadataOverrides()
        edits.remove(.dictionary(gps))
        edits.set(.title, to: .text("RESUMED"))
        let items = urls.map { url -> InputItem in
            var item = InputItem(source: url, relativeDirectory: "")
            item.metadataOverrides = edits
            return item
        }
        let journalURL = root.appendingPathComponent("support/journal.json")
        let crash = root.appendingPathComponent("crash/journal.json")
        try FileManager.default.createDirectory(at: crash.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let pipeline = Pipeline(output: OutputSettings(format: .png))
        _ = await BatchRunner.run(items, pipeline: pipeline, mode: .newFolder(out), concurrency: 1,
                                  journal: journalURL, events: { event in
            // The journal as it is on disk after the first image: as if the app quit then.
            guard event.index == 0, event.stage == .done,
                  !FileManager.default.fileExists(atPath: crash.path) else { return }
            try? FileManager.default.copyItem(at: journalURL, to: crash)
        })
        let journal = try XCTUnwrap(RunJournal.pending(at: crash))
        let plan = ResumePlan.make(journal: journal, existing: [],
                                   isReadable: { FileManager.default.isReadableFile(atPath: $0) },
                                   directoryExists: { _ in true })
        XCTAssertFalse(plan.toRun.isEmpty)
        XCTAssertTrue(plan.toRun.allSatisfy { $0.metadataOverrides == edits })
        let resumedOut = root.appendingPathComponent("resumed", isDirectory: true)
        let report = await BatchRunner.run(plan.toRun, pipeline: plan.pipeline, mode: .newFolder(resumedOut))
        XCTAssertEqual(report.written.count, plan.toRun.count)
        for url in report.written {
            let written = try WrittenFile(url: url)
            XCTAssertNil(written.sub(kCGImagePropertyGPSDictionary), url.lastPathComponent)
            XCTAssertEqual(written.xmp("dc:title"), "RESUMED")
        }
    }

    func testAJournalWithOneHostileOverrideIsRejectedWhole() async throws {
        let urls = try [photo("a.jpg"), photo("b.jpg")]
        var edits = MetadataOverrides()
        edits.set(.title, to: .text("T"))
        let items = urls.map { url -> InputItem in
            var item = InputItem(source: url, relativeDirectory: "")
            item.metadataOverrides = edits
            return item
        }
        let journalURL = root.appendingPathComponent("support/journal.json")
        let crash = root.appendingPathComponent("crash/journal.json")
        try FileManager.default.createDirectory(at: crash.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = await BatchRunner.run(items, pipeline: Pipeline(output: OutputSettings(format: .png)),
                                  mode: .newFolder(root.appendingPathComponent("out", isDirectory: true)),
                                  concurrency: 1, journal: journalURL, events: { event in
            guard event.index == 0, event.stage == .done,
                  !FileManager.default.fileExists(atPath: crash.path) else { return }
            try? FileManager.default.copyItem(at: journalURL, to: crash)
        })
        XCTAssertNotNil(RunJournal.pending(at: crash), "the journal as written is accepted")
        // The second item's changes replaced by a field outside the allowlist (a MakerNote): nothing is resumed,
        // not even the first item.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: crash)) as? [String: Any])
        var journalItems = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(journalItems.count, 2)
        journalItems[1]["metadataOverrides"] = ["fields": [[
            "field": ["kind": "custom", "namespace": "exif", "key": "MakerNote"],
            "value": ["kind": "text", "text": "x"],
        ]]]
        object["items"] = journalItems
        try JSONSerialization.data(withJSONObject: object).write(to: crash)
        XCTAssertNil(RunJournal.pending(at: crash))
    }

    func testOldJournalItemsDecodeWithoutOverrides() throws {
        let json = #"{"path": "/p/a.jpg", "relativeDirectory": ""}"#
        let item = try JSONDecoder().decode(RunJournal.Item.self, from: Data(json.utf8))
        XCTAssertNil(item.metadataOverrides)
    }

    func testOverridesRoundTripAndHostileOnesAreRejected() throws {
        var edits = MetadataOverrides()
        edits.set(.location, to: .location(latitude: 1.5, longitude: -2, altitude: 30))
        edits.set(.keywords, to: .keywords(["a", "b"]))
        edits.set(.dateTaken, to: .date(Date(timeIntervalSinceReferenceDate: 1000)))
        edits.set(.rating, to: .rating(3))
        edits.set(.custom(.iptc, "Headline"), to: .text("H"))
        edits.remove(.xmp("xmpMM:History"))
        edits.remove(.property(dictionary: "{Exif}", key: "LensSerialNumber"))
        edits.remove(.property(dictionary: "{TIFF}", key: "Artist"))
        let data = try JSONEncoder().encode(edits)
        XCTAssertEqual(try JSONDecoder().decode(MetadataOverrides.self, from: data), edits)
        for hostile in [
            #"{"fields":[{"field":{"kind":"custom","namespace":"exif","key":"MakerNote"},"value":{"kind":"text","text":"x"}}]}"#,
            #"{"fields": [{"field": {"kind": "location"}, "value": {"kind": "location", "latitude": 99, "longitude": 0}}]}"#,
            #"{"fields": [{"field": {"kind": "title"}, "value": {"kind": "nonsense"}}]}"#,
            #"{"removedPaths": [{"kind": "xmp", "path": "\#(String(repeating: "x", count: 600))"}]}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(MetadataOverrides.self, from: Data(hostile.utf8)), hostile)
        }
    }
}

/// Fix round 1 minors: wider removals shown on every row they take, link fallbacks, bidi controls, and the
/// condition and remove-all paths.
final class MetadataOverridesFixTests: XCTestCase {
    private let gps = kCGImagePropertyGPSDictionary as String
    private let exif = kCGImagePropertyExifDictionary as String

    func testWiderRemovalsMarkEveryRowTheyTake() {
        var edits = MetadataOverrides()
        let altitude = MetadataPath.property(dictionary: gps, key: kCGImagePropertyGPSAltitude as String)
        let digitized = MetadataPath.property(dictionary: exif, key: kCGImagePropertyExifDateTimeDigitized as String)
        XCTAssertFalse(edits.isRemoved(altitude))
        edits.remove(.dictionary(gps))
        XCTAssertTrue(edits.isRemoved(altitude))
        edits.remove(.property(dictionary: exif, key: kCGImagePropertyExifDateTimeOriginal as String))
        XCTAssertTrue(edits.isRemoved(digitized))
        XCTAssertTrue(edits.isRemoved(.property(dictionary: kCGImagePropertyTIFFDictionary as String, key: "DateTime")))
        edits.set(.location, to: .location(latitude: 1, longitude: 2, altitude: nil))
        XCTAssertTrue(edits.isRemoved(altitude), "a set position replaces the old GPS fields")
        XCTAssertFalse(edits.isRemoved(.dictionary(gps)))
        var other = MetadataOverrides()
        other.remove(.dictionary("{MakerApple}"))
        XCTAssertTrue(other.isRemoved(.property(dictionary: "{MakerApple}", key: "1")))
    }

    func testMirrorNamespaceLinksLandOnAVisibleRow() throws {
        let root = try TestImages.tempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try MetadataTestSupport.source(root.appendingPathComponent("a.jpg"), properties: [
            gps: [kCGImagePropertyGPSLatitude as String: 1.0, kCGImagePropertyGPSLongitude as String: 2.0],
            kCGImagePropertyExifAuxDictionary as String: [kCGImagePropertyExifAuxSerialNumber as String: "AUXSN"],
        ])
        let inspection = MetadataInspection.read(url)
        XCTAssertEqual(inspection.entry(for: .xmp("exif:GPSLatitude"))?.path, .dictionary(gps))
        XCTAssertEqual(inspection.entry(for: .xmp("aux:SerialNumber"))?.value, "AUXSN")
        XCTAssertEqual(inspection.entry(for: .xmp("exifEX:LensSerialNumber"))?.group, .camera, "its group's first row")
    }

    func testBidiControlsAreNotWrittenBack() {
        XCTAssertEqual(MetadataOverrideValue.text("a\u{202E}b\u{2066}c").validated, .text("abc"))
        XCTAssertEqual(MetadataOverrideValue.keywords(["\u{202E}x"]).validated, .keywords(["x"]))
    }

    func testOverrideWinsOverAConditionsSetMetadataAndPositionUnderRemoveAll() async throws {
        let root = try TestImages.tempDir().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try MetadataTestSupport.source(root.appendingPathComponent("a.jpg"), properties: [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFArtist as String: "SRCARTIST"],
        ])
        var branch = MetadataOptions(isEnabled: true, removeAll: true)
        branch.artist = "BRANCHARTIST"
        let conditional = ConditionalStep(conditions: [.width(.atLeast, 0)], then: [.metadata(branch)])
        let pipeline = Pipeline(steps: [PipelineStep(operation: .condition(conditional))],
                                output: OutputSettings(format: .png))
        var item = InputItem(source: url, relativeDirectory: "")
        item.metadataOverrides.set(.creator, to: .text("PANELARTIST"))
        item.metadataOverrides.set(.location, to: .location(latitude: 10, longitude: 20, altitude: nil))
        let report = await BatchRunner.run([item], pipeline: pipeline,
                                           mode: .newFolder(root.appendingPathComponent("out", isDirectory: true)))
        let written = try WrittenFile(url: try XCTUnwrap(report.written.first))
        XCTAssertTrue(written.contains("PANELARTIST"))
        XCTAssertFalse(written.contains("BRANCHARTIST"))
        XCTAssertFalse(written.contains("SRCARTIST"))
        let position = try XCTUnwrap(written.sub(kCGImagePropertyGPSDictionary))
        XCTAssertEqual((position[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue ?? 0, 10, accuracy: 1e-4)
    }
}
