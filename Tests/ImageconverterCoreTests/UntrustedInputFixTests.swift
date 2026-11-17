import CoreGraphics
import ImageIO
import XCTest
@testable import ImageconverterCore

/// Bug check fixes for untrusted input: nested conditions in saved pipelines, GPS inside XMP location structures,
/// XML-illegal characters in the output XMP.
final class UntrustedInputFixTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: nested conditions

    /// A pipeline file with `depth` conditions, each in the previous one's Then branch.
    private func nestedPipelineJSON(depth: Int) -> Data {
        var inner = #"{"conditions":[{"hasGPS":{"_0":true}}],"then":[{"skip":{}}]}"#
        for _ in 1..<depth {
            inner = #"{"conditions":[{"hasGPS":{"_0":true}}],"then":[{"step":{"_0":{"id":""#
                + UUID().uuidString + #"","isEnabled":true,"operation":{"condition":{"_0":"# + inner + "}}}}}]}"
        }
        let json = #"{"steps":[{"id":""# + UUID().uuidString
            + #"","isEnabled":true,"operation":{"condition":{"_0":"# + inner + "}}}]}"
        return Data(json.utf8)
    }

    /// Decodes on a thread with a 512 KB stack, as background workers have.
    private func decodeOnSmallStack(_ data: Data) -> Result<Pipeline, Error>? {
        var result: Result<Pipeline, Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try JSONDecoder().decode(Pipeline.self, from: data) }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        return result
    }

    func testDeeplyNestedConditionIsRefusedNotCrashing() throws {
        let decoded = try XCTUnwrap(decodeOnSmallStack(nestedPipelineJSON(depth: 60))).get()
        XCTAssertEqual(decoded.steps.count, 1)
        guard case .condition(let outer) = decoded.steps[0].operation else { return XCTFail("condition dropped") }
        XCTAssertEqual(outer.then, [], "the nested condition is left out")
        XCTAssertEqual(decoded.loadNotes.notes, [ConditionalStep.nestedConditionNote(count: 1)])

        // One level of condition, with steps in its branches, loads as before and says nothing.
        let resize = PipelineStep(operation: .resize(ResizeOptions()))
        let plain = Pipeline(steps: [PipelineStep(operation: .condition(ConditionalStep(
            then: [.step(resize), .skip], otherwise: [.step(resize)])))])
        let reloaded = try XCTUnwrap(decodeOnSmallStack(try JSONEncoder().encode(plain))).get()
        XCTAssertEqual(reloaded, plain)
        XCTAssertEqual(reloaded.loadNotes.notes, [])

        // Two nested ones, in either branch: one note with the count.
        let nested = PipelineStep(operation: .condition(ConditionalStep(then: [.skip])))
        let twice = Pipeline(steps: [PipelineStep(operation: .condition(ConditionalStep(
            then: [.step(nested), .step(resize)], otherwise: [.step(nested)])))])
        let pruned = try XCTUnwrap(decodeOnSmallStack(try JSONEncoder().encode(twice))).get()
        XCTAssertEqual(pruned.loadNotes.notes, [ConditionalStep.nestedConditionNote(count: 2)])
        guard case .condition(let kept) = pruned.steps[0].operation else { return XCTFail("condition dropped") }
        XCTAssertEqual(kept.then, [.step(resize)])
        XCTAssertEqual(kept.otherwise, [])
    }

    // MARK: GPS in XMP locations

    /// A JPEG whose only location is IPTC Extension's LocationCreated (and LocationShown) holding
    /// exif:GPSLatitude/GPSLongitude, as Lightroom and Photo Mechanic write it; plus a title that must survive.
    private func locationStructPhoto(shown: Bool = false) throws -> URL {
        let place = { (lat: String, lon: String) in
            "<rdf:Bag><rdf:li rdf:parseType=\"Resource\"><exif:GPSLatitude>\(lat)</exif:GPSLatitude>"
                + "<exif:GPSLongitude>\(lon)</exif:GPSLongitude><Iptc4xmpExt:City>Stockholm</Iptc4xmpExt:City>"
                + "</rdf:li></rdf:Bag>"
        }
        let shownXML = shown ? "<Iptc4xmpExt:LocationShown>\(place("57,42.0N", "11,58.0E"))</Iptc4xmpExt:LocationShown>" : ""
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/" \
        xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <Iptc4xmpExt:LocationCreated>\(place("59,20.0N", "18,4.0E"))</Iptc4xmpExt:LocationCreated>\(shownXML)
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">KEEPTITLE</rdf:li></rdf:Alt></dc:title>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let meta = try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData))
        let url = root.appendingPathComponent("place-\(UUID().uuidString).jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(dest, TestImages.make(width: 40, height: 20), meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testPrivacyFindsXMPLocationCreatedGPS() async throws {
        let url = try locationStructPhoto(shown: true)
        let source = try WrittenFile(url: url)
        XCTAssertNil(source.sub(kCGImagePropertyGPSDictionary), "the fixture has no {GPS} dictionary")
        let location = try XCTUnwrap(PrivacyScanner.scan(url).findings.first { $0.kind == .location })
        let created = try XCTUnwrap(location.details.first { $0.path == .xmp("Iptc4xmpExt:LocationCreated") })
        XCTAssertTrue(created.value.contains("59,20.0N") && created.value.contains("18,4.0E"), created.value)
        XCTAssertLessThanOrEqual(created.value.count, PrivacyDetail.maxLength)
        let shown = try XCTUnwrap(location.details.first { $0.path == .xmp("Iptc4xmpExt:LocationShown") })
        XCTAssertTrue(shown.value.contains("57,42.0N"), shown.value)

        // The suggestion removes it: a real encode, read again.
        let options = PrivacyScanner.scan(url).suggestedMetadataOptions
        XCTAssertEqual(options.location, .remove)
        let written = try await MetadataTestSupport.convert(url, options: options, root: root)
        XCTAssertNil(PrivacyScanner.scan(written.url).findings.first { $0.kind == .location })
        XCTAssertFalse(written.contains("GPSLatitude") || written.contains("59,20.0N") || written.contains("57,42.0N"))
        XCTAssertEqual(written.xmp("dc:title[x-default]"), "KEEPTITLE")
    }

    func testRemoveGPSAlsoRemovesXMPLocations() async throws {
        for format in [OutputFormat.jpeg, .png] {
            let url = try locationStructPhoto(shown: true)
            var edits = MetadataOverrides()
            edits.remove(.dictionary(kCGImagePropertyGPSDictionary as String))
            var item = InputItem(source: url, relativeDirectory: "")
            item.metadataOverrides = edits
            let out = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
            let report = await BatchRunner.run([item], pipeline: Pipeline(output: OutputSettings(format: format)),
                                               mode: .newFolder(out))
            XCTAssertEqual(report.failures, [])
            let written = try WrittenFile(url: try XCTUnwrap(report.written.first))
            XCTAssertFalse(written.contains("GPSLatitude") || written.contains("59,20.0N") || written.contains("57,42.0N"),
                           "\(format)")
            XCTAssertNil(PrivacyScanner.scan(written.url).findings.first { $0.kind == .location }, "\(format)")
            XCTAssertEqual(written.xmp("dc:title[x-default]"), "KEEPTITLE", "\(format)")
        }
    }

    // MARK: XML-illegal characters

    /// The output XMP serialised and parsed again, as a reader of the written file would.
    private func reparsedXMP(_ props: [String: Any]) throws -> CGImageMetadata? {
        let meta = try XCTUnwrap((props[MetadataOps.xmpPropertyKey] as? OutputXMP)?.metadata)
        let data = try XCTUnwrap(CGImageMetadataCreateXMPData(meta, nil))
        return CGImageMetadataCreateFromXMPData(data)
    }

    private func string(_ meta: CGImageMetadata?, _ path: String) -> String? {
        guard let meta else { return nil }
        return CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) as String?
    }

    func testNoncharactersStripped() throws {
        // Swift literals refuse some noncharacters, so the scalars are built from their values.
        let nonchars: [UInt32] = [0xFFFE, 0xFFFF, 0xFDD0, 0xFDEF, 0x1FFFE, 0x10FFFF]
        var text = String.UnicodeScalarView()
        for (index, value) in nonchars.enumerated() {
            text.append(Unicode.Scalar(UInt8(ascii: "a") + UInt8(index)))
            text.append(try XCTUnwrap(Unicode.Scalar(value)))
        }
        XCTAssertEqual(MetadataFields.sanitized(String(text)), "abcdef")
        XCTAssertEqual(MetadataFields.sanitized("ok \u{FDCF}\u{FDF0} é"), "ok \u{FDCF}\u{FDF0} é")

        var options = MetadataOptions(isEnabled: true, removeLocation: false)
        options.title = "bad\u{FFFF}title"
        options.description = "bad\u{FFFE}x"
        options.artist = "Ann"
        let typed = try reparsedXMP(MetadataOps.output(options, properties: [:], metadata: nil))
        XCTAssertNotNil(typed, "the XMP packet must parse")
        XCTAssertEqual(string(typed, "dc:title[x-default]"), "badtitle")
        XCTAssertEqual(string(typed, "dc:description[x-default]"), "badx")
        XCTAssertEqual(string(typed, "dc:creator[0]"), "Ann")

        // A source file's IPTC values are mirrored into XMP by syncIPTC.
        let iptc: [String: Any] = [
            kCGImagePropertyIPTCObjectName as String: "src\u{FFFF}name",
            kCGImagePropertyIPTCKeywords as String: ["k\u{FFFE}1", "k2"],
            kCGImagePropertyIPTCCity as String: "Stockholm",
        ]
        var plain = MetadataOptions(isEnabled: true, removeLocation: false)
        plain.artist = "Ann"
        let mirrored = try reparsedXMP(MetadataOps.output(
            plain, properties: [kCGImagePropertyIPTCDictionary as String: iptc], metadata: nil))
        XCTAssertNotNil(mirrored, "the XMP packet must parse")
        XCTAssertEqual(string(mirrored, "dc:title[x-default]"), "srcname")
        XCTAssertEqual(string(mirrored, "photoshop:City"), "Stockholm")
        XCTAssertEqual(string(mirrored, "dc:creator[0]"), "Ann")
    }
}
