import CoreGraphics
import ImageIO
import XCTest
@testable import ImageconverterCore

/// Redact final fixes: face regions found by namespace and name (any prefix), and the converted copy's note naming
/// the preset image steps it didn't apply.
final class RedactFinalFixTests: XCTestCase {
    private static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    private static let msPhoto = "http://ns.microsoft.com/photo/1.2/"

    /// XMP whose region tags use their own prefixes (a file may declare any prefix for a namespace).
    private func metadata() throws -> CGImageMetadata {
        let meta = CGImageMetadataCreateMutable()
        for (prefix, namespace) in [("ext", Self.iptcExt), ("msp", Self.msPhoto),
                                    ("dc", "http://purl.org/dc/elements/1.1/"), ("other", "http://example.com/ns/")] {
            XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(meta, namespace as CFString, prefix as CFString, nil))
        }
        let values: [(namespace: String, path: String)] = [
            (Self.iptcExt, "ext:PersonInImage"), (Self.msPhoto, "msp:RegionInfo"),
            ("http://purl.org/dc/elements/1.1/", "dc:source"), ("http://example.com/ns/", "other:PersonInImage"),
        ]
        for (namespace, path) in values {
            let parts = path.split(separator: ":").map(String.init)
            let (prefix, name) = (parts[0], parts[1])
            let tag = try XCTUnwrap(CGImageMetadataTagCreate(namespace as CFString, prefix as CFString, name as CFString,
                                                             .string, "Alice" as CFString))
            XCTAssertTrue(CGImageMetadataSetTagWithPath(meta, nil, "\(prefix):\(name)" as CFString, tag))
        }
        return meta
    }

    func testFaceRegionsMatchByNamespaceAndNameNotPrefix() throws {
        let properties: [String: Any] = [MetadataOps.xmpPropertyKey: OutputXMP(metadata: try metadata())]
        let (result, removed) = MetadataOps.removingFaceRegions(from: properties)
        XCTAssertTrue(removed)
        let meta = try XCTUnwrap((result[MetadataOps.xmpPropertyKey] as? OutputXMP)?.metadata)
        XCTAssertNil(CGImageMetadataCopyTagWithPath(meta, nil, "ext:PersonInImage" as CFString))
        XCTAssertNil(CGImageMetadataCopyTagWithPath(meta, nil, "msp:RegionInfo" as CFString))
        XCTAssertNotNil(CGImageMetadataCopyTagWithPath(meta, nil, "dc:source" as CFString))
        XCTAssertNotNil(CGImageMetadataCopyTagWithPath(meta, nil, "other:PersonInImage" as CFString),
                       "the same name in another namespace stays")
    }

    func testAConvertedCopyNamesThePresetStepsItDidNotApply() throws {
        let root = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("presets", isDirectory: true)
        let store = PresetStore(directory: directory)
        let resize = PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(10))))
        let watermark = PipelineStep(operation: .watermark(WatermarkOptions()))
        let presetRedact = PipelineStep(operation: .redact(RedactOptions(target: .text)))
        let saved = Preset(name: "Web", pipeline: Pipeline(steps: [resize, presetRedact, watermark]))
        try store.save(saved)
        let redact = PipelineStep(operation: .redact(RedactOptions(target: .faces)))
        let branch = PipelineStep(operation: .condition(ConditionalStep(then: [.preset(PresetLink(saved)), .copyOriginal])))
        let resolved = Pipeline(steps: [redact, branch])
            .resolved(for: ItemFacts(width: 3000, height: 100, format: .png), presets: .folder(directory))
        XCTAssertEqual(resolved.disposition, .process)
        XCTAssertEqual(resolved.pipeline.steps, [redact, presetRedact], "only the Redact steps run")
        XCTAssertTrue(resolved.notes.contains(Redaction.convertedToRedactNote))
        XCTAssertTrue(resolved.notes.contains("Not applied to the converted copy: the preset's Resize, Watermark steps"),
                      "\(resolved.notes)")
    }
}
