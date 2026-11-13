import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class CompressionSearchTests: XCTestCase {
    private let noisy = TestImages.noise(width: 160, height: 120)

    private func size(_ quality: Double, _ image: CGImage? = nil) throws -> Int {
        try ImageEncoder.encode(image ?? noisy, properties: [:], settings: .init(format: .jpeg, quality: quality)).count
    }

    func testQualityModeIsOneEncodeAtQuality() throws {
        let result = try CompressionSearch.encode(noisy, properties: [:], settings: .init(format: .jpeg, quality: 0.7))
        XCTAssertEqual(result.data.count, try size(0.7))
        XCTAssertEqual(try XCTUnwrap(result.quality), 0.7, accuracy: 1e-9)
        XCTAssertNil(result.note)
    }

    func testTargetSizeHitsBelowTarget() throws {
        let low = try size(0.2), high = try size(0.95)
        let target = (low + high) / 2
        var settings = OutputSettings(format: .jpeg, quality: 0.82)
        settings.compression = .targetSize(bytes: target)
        let result = try CompressionSearch.encode(noisy, properties: [:], settings: settings)
        XCTAssertLessThanOrEqual(result.data.count, target)
        XCTAssertGreaterThan(result.data.count, low)
        XCTAssertNil(result.note)
        let quality = try XCTUnwrap(result.quality)
        XCTAssertGreaterThan(quality, 0.2)
        XCTAssertLessThan(quality, 0.95)
    }

    func testTargetSizeUnreachableReturnsNote() throws {
        var settings = OutputSettings(format: .jpeg)
        settings.compression = .targetSize(bytes: 100)
        let result = try CompressionSearch.encode(noisy, properties: [:], settings: settings)
        XCTAssertEqual(result.data.count, try size(0))
        XCTAssertEqual(result.quality, 0)
        let note = try XCTUnwrap(result.note)
        XCTAssertTrue(note.hasPrefix("Couldn't reach "), note)
        XCTAssertTrue(note.contains("smallest is"), note)
    }

    func testMaxSizeKeepsQualityWhenSmallEnough() throws {
        var settings = OutputSettings(format: .jpeg, quality: 0.6)
        settings.compression = .maxSize(bytes: try size(0.6) + 10)
        let result = try CompressionSearch.encode(noisy, properties: [:], settings: settings)
        XCTAssertEqual(result.data.count, try size(0.6))
        XCTAssertEqual(try XCTUnwrap(result.quality), 0.6, accuracy: 1e-9)
        XCTAssertNil(result.note)
    }

    func testMaxSizeLowersQualityWhenTooLarge() throws {
        var settings = OutputSettings(format: .jpeg, quality: 0.95)
        let limit = (try size(0.3) + size(0.6)) / 2
        settings.compression = .maxSize(bytes: limit)
        let result = try CompressionSearch.encode(noisy, properties: [:], settings: settings)
        XCTAssertLessThanOrEqual(result.data.count, limit)
        XCTAssertLessThan(try XCTUnwrap(result.quality), 0.95)
    }

    func testMaxSizeFailsWhenImpossible() throws {
        var settings = OutputSettings(format: .jpeg)
        settings.compression = .maxSize(bytes: 100)
        XCTAssertThrowsError(try CompressionSearch.encode(noisy, properties: [:], settings: settings)) { error in
            guard case ConversionError.sizeUnreachable(let limit, let smallest) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(limit, 100)
            XCTAssertGreaterThan(smallest, 100)
            XCTAssertTrue((error as? ConversionError)?.reason.hasPrefix("Can't get under ") == true)
        }
    }

    func testSmartPicksLowerQualityForFlatImage() throws {
        var settings = OutputSettings(format: .jpeg)
        settings.compression = .smart
        let flat = try CompressionSearch.encode(CompressionImages.gradient(width: 160, height: 120),
                                                properties: [:], settings: settings)
        let busy = try CompressionSearch.encode(noisy, properties: [:], settings: settings)
        let flatQuality = try XCTUnwrap(flat.quality), busyQuality = try XCTUnwrap(busy.quality)
        XCTAssertLessThan(flatQuality, busyQuality)
        for quality in [flatQuality, busyQuality] {
            XCTAssertGreaterThanOrEqual(quality, 0.40)
            XCTAssertLessThanOrEqual(quality, 0.95)
        }
    }

    func testFormatsWithoutQualityIgnoreCompression() throws {
        var settings = OutputSettings(format: .png, optimizePNG: false)
        settings.compression = .maxSize(bytes: 10)
        let result = try CompressionSearch.encode(noisy, properties: [:], settings: settings)
        XCTAssertNil(result.quality)
        XCTAssertNil(result.note)
        XCTAssertEqual(result.data, try ImageEncoder.encode(noisy, properties: [:], settings: settings))
    }

    func testCompressionModeCodingIsLenient() throws {
        var settings = OutputSettings(format: .heic)
        settings.compression = .targetSize(bytes: 50_000)
        let round = try JSONDecoder().decode(OutputSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(round, settings)
        let old = try JSONDecoder().decode(OutputSettings.self, from: Data(#"{"format":"jpeg"}"#.utf8))
        XCTAssertEqual(old.compression, .quality)
        let unknown = try JSONDecoder().decode(OutputSettings.self,
                                               from: Data(#"{"format":"jpeg","compression":{"magic":{}}}"#.utf8))
        XCTAssertEqual(unknown.compression, .quality)
        let negative = try JSONDecoder().decode(
            OutputSettings.self, from: Data(#"{"compression":{"maxSize":{"bytes":-5}}}"#.utf8))
        XCTAssertEqual(negative.compression, .quality)
    }
}

final class CompressionBatchTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func item() throws -> InputItem {
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.noise(width: 160, height: 120), to: url, type: .png)
        return InputItem(source: url, relativeDirectory: "")
    }

    private func writtenSize(_ report: BatchReport) throws -> Int {
        let written = try XCTUnwrap(report.written.first)
        return try XCTUnwrap(try written.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    func testEstimateEqualsBatchWithTargetSize() async throws {
        let item = try item()
        var pipeline = Pipeline(output: .init(format: .jpeg))
        pipeline.output.compression = .targetSize(bytes: 12_000)
        let estimate = try SizeEstimator.render(item: item, pipeline: pipeline)
        let report = await BatchRunner.run([item], pipeline: pipeline,
                                           mode: .newFolder(dir.appendingPathComponent("out", isDirectory: true)))
        XCTAssertEqual(estimate.bytes, try writtenSize(report))
        XCTAssertLessThanOrEqual(estimate.bytes, 12_000)
        XCTAssertNotNil(estimate.quality)
        XCTAssertNil(estimate.note)
        XCTAssertTrue(report.notes.isEmpty)
    }

    func testUnreachableTargetIsANoteNotAFailure() async throws {
        let item = try item()
        var pipeline = Pipeline(output: .init(format: .jpeg))
        pipeline.output.compression = .targetSize(bytes: 50)
        let report = await BatchRunner.run([item], pipeline: pipeline,
                                           mode: .newFolder(dir.appendingPathComponent("out", isDirectory: true)))
        XCTAssertEqual(report.written.count, 1)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.notes.map(\.source), [item.source])
        XCTAssertTrue(report.notes.first?.text.hasPrefix("Couldn't reach ") == true)
    }

    func testImpossibleMaxSizeFailsTheFile() async throws {
        let item = try item()
        var pipeline = Pipeline(output: .init(format: .jpeg))
        pipeline.output.compression = .maxSize(bytes: 50)
        let report = await BatchRunner.run([item], pipeline: pipeline,
                                           mode: .newFolder(dir.appendingPathComponent("out", isDirectory: true)))
        XCTAssertTrue(report.written.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures.first?.reason.hasPrefix("Can't get under ") == true)
    }

    func testPNGEstimateSkipsOptimisationAndSaysSo() throws {
        let item = try item()
        let estimate = try SizeEstimator.render(item: item, pipeline: Pipeline(output: .init(format: .png)))
        XCTAssertEqual(estimate.note, "Optimised PNG may be smaller")
        XCTAssertNil(estimate.quality)
        let plain = try SizeEstimator.render(item: item,
                                             pipeline: Pipeline(output: .init(format: .png, optimizePNG: false)))
        XCTAssertNil(plain.note)
        XCTAssertEqual(plain.bytes, estimate.bytes)
    }
}
