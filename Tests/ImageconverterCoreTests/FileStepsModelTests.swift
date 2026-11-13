import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class FileStepsModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testMilestone2PipelineStillDecodes() throws {
        let step = PipelineStep(operation: .resize(ResizeOptions()))
        let full = try JSONEncoder().encode(Pipeline(steps: [step]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: full) as? [String: Any])
        object.removeValue(forKey: "metadata")
        object.removeValue(forKey: "rename")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Pipeline.self, from: old)
        XCTAssertEqual(decoded.steps, [step])
        XCTAssertEqual(decoded.metadata, MetadataOptions())
        XCTAssertEqual(decoded.rename, RenameOptions())
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(Pipeline.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, Pipeline())
    }

    func testRoundTripWithFileSteps() throws {
        var pipeline = Pipeline(steps: [PipelineStep(operation: .colorProfile(.sRGB))])
        pipeline.metadata = MetadataOptions(isEnabled: true, removeAll: false, removeLocation: false,
                                            removeCamera: true, artist: "A", copyright: "", description: "D")
        pipeline.rename = RenameOptions(isEnabled: true, pattern: "{date}_{counter:000}", counterStart: 5)
        let data = try JSONEncoder().encode(pipeline)
        XCTAssertEqual(try JSONDecoder().decode(Pipeline.self, from: data), pipeline)
    }

    func testMetadataSummaries() {
        var options = MetadataOptions(removeLocation: false)
        XCTAssertEqual(options.summary, "keep")
        options.removeAll = true
        XCTAssertEqual(options.summary, "strip all")
        options = MetadataOptions(removeLocation: true, removeCamera: false)
        XCTAssertEqual(options.summary, "strip GPS")
        options = MetadataOptions(removeLocation: false, removeCamera: true)
        XCTAssertEqual(options.summary, "strip camera")
        options = MetadataOptions(removeLocation: true, removeCamera: true)
        XCTAssertEqual(options.summary, "strip GPS + camera")
        options.artist = "Me"
        options.copyright = ""
        XCTAssertEqual(options.summary, "strip GPS + camera · set artist, copyright")
        options.description = "x"
        XCTAssertEqual(options.summary, "strip GPS + camera · set artist, copyright, description")
        XCTAssertEqual(RenameOptions(pattern: "{name}-{counter}").summary, "{name}-{counter}")
    }

    func testHeaderReadsSizeAndExif() throws {
        let url = dir.appendingPathComponent("a.jpg")
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2024:06:01 23:30:00"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "iPhone 15 Pro"],
        ]
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .jpeg, properties: properties)
        let header = try XCTUnwrap(ImageLoader.header(of: url))
        XCTAssertEqual(header.width, 40)
        XCTAssertEqual(header.height, 20)
        let exif = header.properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = header.properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2024:06:01 23:30:00")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel as String] as? String, "iPhone 15 Pro")
    }

    func testHeaderNilForJunk() throws {
        let url = dir.appendingPathComponent("junk.jpg")
        try Data("not an image".utf8).write(to: url)
        XCTAssertNil(ImageLoader.header(of: url))
    }
}
