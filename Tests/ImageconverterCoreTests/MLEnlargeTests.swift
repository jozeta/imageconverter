import CoreGraphics
@testable import ImageconverterCore
import XCTest

/// A stand-in for Apple's model: nearest neighbour 4×, with a status it reports and a count of sessions made.
/// It never touches VideoToolbox, so no test runs (or downloads) the real model.
final class FakeScaler: SuperResolutionScaler, @unchecked Sendable {
    let status: MLEnlargeAvailability
    /// Writes this into every alpha byte of its result (to prove the model's alpha is ignored).
    let alphaOut: UInt8?
    /// Thrown by every `upscale` (a model that fails or doesn't answer).
    let failure: Error?
    let speaksFromApp: Bool
    private let lock = NSLock()
    private var sessionsMade = 0
    private var tileSizes: [String] = []

    init(status: MLEnlargeAvailability = .ready, alphaOut: UInt8? = nil, failure: Error? = nil,
         speaksFromApp: Bool = false) {
        self.status = status
        self.alphaOut = alphaOut
        self.failure = failure
        self.speaksFromApp = speaksFromApp
    }

    var factor: Int { 4 }
    var sessions: Int { lock.withLock { sessionsMade } }
    var tiles: [String] { lock.withLock { tileSizes } }

    func availability() -> MLEnlargeAvailability { status }

    func makeSession(width: Int, height: Int, colorSpace: CGColorSpace) throws -> any SuperResolutionSession {
        lock.withLock { sessionsMade += 1 }
        return Session(owner: self, width: width, height: height)
    }

    fileprivate func record(_ tile: RGBA8Tile) { lock.withLock { tileSizes.append("\(tile.width)x\(tile.height)") } }

    final class Session: SuperResolutionSession {
        let owner: FakeScaler
        let width: Int
        let height: Int

        init(owner: FakeScaler, width: Int, height: Int) {
            self.owner = owner
            self.width = width
            self.height = height
        }

        func upscale(_ tile: RGBA8Tile) throws -> RGBA8Tile {
            XCTAssertEqual(tile.width, width)
            XCTAssertEqual(tile.height, height)
            if let failure = owner.failure { throw failure }
            owner.record(tile)
            var result = MLEnlargeTests.nearest(tile.pixels, width: tile.width, height: tile.height, by: 4)
            if let alpha = owner.alphaOut {
                for index in stride(from: 3, to: result.count, by: 4) { result[index] = alpha }
            }
            return RGBA8Tile(width: tile.width * 4, height: tile.height * 4, pixels: result)
        }
    }
}

final class MLEnlargeTests: XCTestCase {
    // MARK: Helpers

    static func nearest(_ pixels: [UInt8], width: Int, height: Int, by factor: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height * 4 * factor * factor)
        let outWidth = width * factor
        for row in 0..<(height * factor) {
            for col in 0..<outWidth {
                let from = ((row / factor) * width + col / factor) * 4
                let into = (row * outWidth + col) * 4
                for channel in 0..<4 { result[into + channel] = pixels[from + channel] }
            }
        }
        return result
    }

    /// `image`'s RGBA8 bytes (premultiplied last) in its own colour space.
    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.interpolationQuality = .none
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func enlarge(_ image: CGImage, factor: Int, scaler: FakeScaler = FakeScaler(),
                         tiling: MLEnlargeTiling = .standard, limits: DecodeLimits = .standard) throws -> CGImage {
        var notes: [String] = []
        return try MLEnlarge.enlarge(image, factor: factor, scaler: scaler, tiling: tiling, limits: limits, notes: &notes)
    }

    private func assertSpansValid(_ spans: [MLEnlargeTiling.Span], length: Int, tiling: MLEnlargeTiling,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(spans.first?.start, 0, file: file, line: line)
        XCTAssertEqual(spans.last?.end, max(1, length), file: file, line: line)
        XCTAssertEqual(spans.first?.overlapBefore, 0, file: file, line: line)
        for (index, span) in spans.enumerated() {
            XCTAssertLessThanOrEqual(span.length, tiling.maxTile, "span \(index) of \(length)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(span.start, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(span.end, max(1, length), "inside the image, never padded", file: file, line: line)
            guard index > 0 else { continue }
            let previous = spans[index - 1]
            XCTAssertGreaterThan(span.start, previous.start, file: file, line: line)
            XCTAssertEqual(span.overlapBefore, previous.end - span.start, file: file, line: line)
            XCTAssertGreaterThanOrEqual(span.overlapBefore, tiling.overlap, "\(length)", file: file, line: line)
            XCTAssertLessThan(span.overlapBefore, span.length, file: file, line: line)
            // Only neighbours overlap, never three tiles at once.
            if index > 1 { XCTAssertGreaterThanOrEqual(span.start, spans[index - 2].end, file: file, line: line) }
        }
        XCTAssertEqual(Set(spans.map(\.length)).count, 1, "one tile size, so one model session", file: file, line: line)
    }

    // MARK: Tiling plan

    func testSpansForTheSizesThatMatter() {
        let tiling = MLEnlargeTiling.standard
        XCTAssertEqual(tiling.spans(length: 1), [.init(start: 0, length: 1, overlapBefore: 0)])
        XCTAssertEqual(tiling.spans(length: 1919), [.init(start: 0, length: 1919, overlapBefore: 0)])
        XCTAssertEqual(tiling.spans(length: 1920), [.init(start: 0, length: 1920, overlapBefore: 0)])
        XCTAssertEqual(tiling.spans(length: 1921), [.init(start: 0, length: 993, overlapBefore: 0),
                                                    .init(start: 928, length: 993, overlapBefore: 65)])
        XCTAssertEqual(tiling.spans(length: 5000).map(\.start), [0, 1645, 3290])
        XCTAssertEqual(tiling.spans(length: 5000).map(\.length), [1710, 1710, 1710])
        XCTAssertEqual(tiling.spans(length: 300), [.init(start: 0, length: 300, overlapBefore: 0)])
        XCTAssertEqual(tiling.spans(length: 8000).count, 5)
        XCTAssertEqual(tiling.spans(length: 6000).count, 4)
        for length in [1, 2, 63, 64, 1919, 1920, 1921, 1984, 3712, 3713, 5000, 6000, 8000, 16_383, 32_767] {
            assertSpansValid(tiling.spans(length: length), length: length, tiling: tiling)
        }
    }

    func testSpansHoldForEveryLengthWithSmallTiles() {
        let tiling = MLEnlargeTiling(maxTile: 64, overlap: 16)
        for length in 1...1500 { assertSpansValid(tiling.spans(length: length), length: length, tiling: tiling) }
    }

    func testGridForWideTallAndBigImages() {
        let tiling = MLEnlargeTiling.standard
        XCTAssertEqual(tiling.spans(length: 5000).count * tiling.spans(length: 300).count, 3)
        XCTAssertEqual(tiling.spans(length: 300).count * tiling.spans(length: 5000).count, 3)
        XCTAssertEqual(tiling.spans(length: 8000).count * tiling.spans(length: 6000).count, 20)
    }

    // MARK: Seams

    func testFeatheredTilesLeaveNoSeams() throws {
        let image = TestImages.noise(width: 300, height: 200)
        let scaler = FakeScaler()
        let result = try enlarge(image, factor: 4, scaler: scaler, tiling: MLEnlargeTiling(maxTile: 64, overlap: 16))
        XCTAssertEqual(result.width, 1200)
        XCTAssertEqual(result.height, 800)
        XCTAssertGreaterThan(scaler.tiles.count, 20, "really tiled")
        XCTAssertEqual(scaler.sessions, 1)
        let expected = Self.nearest(Self.rgba(image), width: 300, height: 200, by: 4)
        XCTAssertEqual(Self.rgba(result), expected, "the blended tiles equal a nearest 4× of the whole image")
    }

    func testStandardTilingAcrossTheModelLimit() throws {
        // 1921 px is one more than the model takes: two tiles with a feathered overlap.
        let image = TestImages.noise(width: 1921, height: 40)
        let scaler = FakeScaler()
        let result = try enlarge(image, factor: 4, scaler: scaler)
        XCTAssertEqual(scaler.tiles, ["993x40", "993x40"])
        XCTAssertEqual(Self.rgba(result), Self.nearest(Self.rgba(image), width: 1921, height: 40, by: 4))
    }

    func testTwoAndThreeTimesComeDownFromTheModelsFourTimes() throws {
        let solid = TestImages.make(width: 150, height: 90)
        for factor in [2, 3] {
            let result = try enlarge(solid, factor: factor, tiling: MLEnlargeTiling(maxTile: 40, overlap: 8))
            XCTAssertEqual(result.width, 150 * factor)
            XCTAssertEqual(result.height, 90 * factor)
            let pixels = Self.rgba(result)
            let first = Array(pixels[0..<4])
            for index in stride(from: 0, to: pixels.count, by: 4) {
                XCTAssertEqual(Array(pixels[index..<index + 4]), first, "a flat colour stays flat at \(factor)×")
                if Array(pixels[index..<index + 4]) != first { break }
            }
        }
    }

    // MARK: Colour and alpha

    func testAlphaIsEnlargedSeparatelyNotByTheModel() throws {
        let image = TestImages.make(width: 50, height: 30, alpha: 0.5)
        let result = try enlarge(image, factor: 2, scaler: FakeScaler(alphaOut: 0))
        XCTAssertTrue(ImageOps.hasAlpha(result))
        let pixels = Self.rgba(result)
        for index in stride(from: 3, to: pixels.count, by: 4) where abs(Int(pixels[index]) - 128) > 1 {
            XCTFail("alpha \(pixels[index]) at \(index)")
            break
        }
    }

    func testOpaqueStaysOpaqueEvenIfTheModelSaysOtherwise() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let opaque = try XCTUnwrap(ctx.makeImage())
        let result = try enlarge(opaque, factor: 2, scaler: FakeScaler(alphaOut: 0))
        XCTAssertFalse(ImageOps.hasAlpha(result))
        XCTAssertEqual(Array(Self.rgba(result)[0..<4]), Array(Self.rgba(opaque)[0..<4]))
    }

    func testColourSpaceIsKeptOrSRGB() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let image = try XCTUnwrap(TestImages.make(width: 10, height: 10).copy(colorSpace: displayP3))
        XCTAssertEqual(try enlarge(image, factor: 2).colorSpace?.name, CGColorSpace.displayP3)
        let gray = try XCTUnwrap(ImageOps.convertColor(TestImages.make(width: 10, height: 10), to: .gray))
        XCTAssertEqual(try enlarge(gray, factor: 2).colorSpace?.name, CGColorSpace.sRGB)
    }

    func testDeepSourcesGetTheEightBitNote() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 16, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                            | CGBitmapInfo.byteOrder16Little.rawValue))
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let deep = try XCTUnwrap(ctx.makeImage())
        var notes: [String] = []
        let result = try MLEnlarge.enlarge(deep, factor: 2, scaler: FakeScaler(), notes: &notes)
        XCTAssertEqual(notes, [MLEnlarge.eightBitNote])
        XCTAssertEqual(result.bitsPerComponent, 8)
        notes = []
        _ = try MLEnlarge.enlarge(TestImages.make(width: 8, height: 8), factor: 2, scaler: FakeScaler(), notes: &notes)
        XCTAssertEqual(notes, [])
    }

    // MARK: Refusals

    func testModelNotReadyRefusesBeforeAnyWork() {
        for status in [MLEnlargeAvailability.downloadRequired, .downloading(progress: 0.4), .unsupportedOS,
                       .unsupportedHardware] {
            let scaler = FakeScaler(status: status)
            XCTAssertThrowsError(try enlarge(TestImages.make(width: 10, height: 10), factor: 2, scaler: scaler)) {
                XCTAssertEqual($0 as? ConversionError, .mlEnlargeUnavailable(status))
            }
            XCTAssertEqual(scaler.sessions, 0)
        }
        XCTAssertEqual(ConversionError.mlEnlargeUnavailable(.downloadRequired).reason,
                       "Not enlarged: Apple's enlargement model isn't downloaded. Open imageconverter and download it "
                        + "in the Resize step.")
        XCTAssertFalse(ConversionError.mlEnlargeUnavailable(.downloadRequired).isRetryable)
    }

    func testResultsOverTheLimitsAreRefusedBeforeAnyWork() {
        let image = TestImages.make(width: 100, height: 100)
        let cases: [(DecodeLimits, String)] = [
            (DecodeLimits(maxPixels: 100_000), "MP"),
            (DecodeLimits(maxSide: 300), "px on one side"),
            (DecodeLimits(maxDecodedBytes: 1_000_000), "memory"),
        ]
        for (limits, words) in cases {
            let scaler = FakeScaler()
            XCTAssertThrowsError(try enlarge(image, factor: 4, scaler: scaler, limits: limits)) { error in
                guard case .mlEnlargeTooLarge? = error as? ConversionError else { return XCTFail("\(error)") }
                XCTAssertTrue((error as? ConversionError)?.reason.contains(words) == true, "\(error)")
                XCTAssertTrue((error as? ConversionError)?.reason.hasPrefix("Not enlarged: ") == true)
            }
            XCTAssertEqual(scaler.sessions, 0)
        }
        // A 4000 × 3000 photo at 4× is 192 MP: within the standard 250 MP.
        // Even with an 8 GB Mac's 2 GB memory limit.
        XCTAssertNoThrow(try MLEnlarge.checkLimits(input: CGSize(width: 4000, height: 3000), factor: 4,
                                                   limits: DecodeLimits(maxDecodedBytes: 2 << 30)))
        XCTAssertThrowsError(try MLEnlarge.checkLimits(input: CGSize(width: 8000, height: 6000), factor: 3))
    }

    // MARK: Model, plan and memory

    func testPlanIsTheFactorWhateverTheEnlargeRule() {
        let options = ResizeOptions(mode: .mlEnlarge(factor: 3), allowEnlarge: false)
        XCTAssertEqual(Geometry.resizePlan(source: CGSize(width: 100, height: 50), options: options),
                       .scale(to: CGSize(width: 300, height: 150)))
        let wild = ResizeOptions(mode: .mlEnlarge(factor: 9))
        XCTAssertEqual(Geometry.resizePlan(source: CGSize(width: 10, height: 10), options: wild),
                       .scale(to: CGSize(width: 40, height: 40)))
        XCTAssertEqual(MLEnlarge.clampedFactor(1), 2)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .resize(options))])
        XCTAssertEqual(pipeline.outputSize(sourceWidth: 100, sourceHeight: 50).width, 300)
        XCTAssertNil(pipeline.decodeHint(sourceWidth: 4000, sourceHeight: 3000))
    }

    func testPeakPixelsCountTheModelsFourTimesTile() {
        let pipeline = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .mlEnlarge(factor: 2))))])
        let peak = pipeline.peakPixels(sourceWidth: 1000, sourceHeight: 1000)
        // The 4 MP output, the 4× tile (16 MP, RGBA) and its half-float buffer (32 MP), and more.
        XCTAssertGreaterThanOrEqual(peak, 4_000_000 + 16_000_000 + 32_000_000)
        XCTAssertEqual(peak, MLEnlarge.workingPixels(input: CGSize(width: 1000, height: 1000), factor: 2)
                       + MLEnlarge.modelSessionPixels)
    }

    func testRoundTripAndSummary() throws {
        let options = ResizeOptions(mode: .mlEnlarge(factor: 3))
        let decoded = try JSONDecoder().decode(ResizeOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .resize(options))])
        XCTAssertEqual(try JSONDecoder().decode(Pipeline.self, from: JSONEncoder().encode(pipeline)), pipeline)
        XCTAssertEqual(ImageOperation.resize(options).summary, "enlarge 3× with machine learning")
    }

}

extension MLEnlargeTests {
    // MARK: Pipeline and batch

    func testPipelineUsesTheInjectedModel() throws {
        let scaler = FakeScaler()
        let pipeline = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .mlEnlarge(factor: 2))))])
        var notes: [String] = []
        let result = try pipeline.apply(to: TestImages.make(width: 30, height: 20), focus: FocusContext(enlarger: scaler),
                                        notes: &notes)
        XCTAssertEqual(result.width, 60)
        XCTAssertEqual(scaler.sessions, 1)
    }

    func testBatchFailsItemsWhenTheModelIsMissingAndNeverDownloads() async throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 20, height: 20), to: url, type: .png)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        let scaler = FakeScaler(status: .downloadRequired)
        var hooks = BatchHooks()
        hooks.enlarger = scaler
        let pipeline = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .mlEnlarge(factor: 2))))])
        let report = await BatchRunner.run([InputItem(source: url, relativeDirectory: "")], pipeline: pipeline,
                                           mode: .newFolder(out), hooks: hooks)
        XCTAssertEqual(report.written, [])
        XCTAssertEqual(report.failures.map(\.reason), [MLEnlargeAvailability.downloadRequired.refusal])
        XCTAssertEqual(scaler.sessions, 0)

        let ready = FakeScaler()
        hooks.enlarger = ready
        let done = await BatchRunner.run([InputItem(source: url, relativeDirectory: "")], pipeline: pipeline,
                                         mode: .newFolder(out), hooks: hooks)
        XCTAssertEqual(done.failures, [])
        XCTAssertEqual(done.written.count, 1)
        XCTAssertEqual(ImageLoader.pixelSize(of: try XCTUnwrap(done.written.first))?.width, 40)
    }

    /// The model download is started from exactly one place: the Resize editor's Download button in the app.
    func testOnlyTheAppsDownloadButtonCanStartTheModelDownload() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var callers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = NoNetworkTests.strippingComments(try String(contentsOf: url, encoding: .utf8))
            if code.contains("downloadConfigurationModel") {
                callers.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        XCTAssertEqual(callers, ["Imageconverter/MLEnlargeDownload.swift"])
    }

    // MARK: Real model (opt-in)

    /// Runs Apple's real model once, only when asked (`IMAGECONVERTER_REAL_ENLARGE=1`) and only when the system
    /// already reports it ready; it never downloads.
    func testRealModelWhenAskedAndReady() throws {
        guard ProcessInfo.processInfo.environment["IMAGECONVERTER_REAL_ENLARGE"] == "1" else {
            throw XCTSkip("Set IMAGECONVERTER_REAL_ENLARGE=1 to run Apple's model")
        }
        guard SystemSuperResolution.shared.availability() == .ready else {
            throw XCTSkip("Model status: \(SystemSuperResolution.shared.availability())")
        }
        var notes: [String] = []
        let image = TestImages.noise(width: 2000, height: 300)
        let result = try MLEnlarge.enlarge(image, factor: 2, scaler: SystemSuperResolution.shared, notes: &notes)
        XCTAssertEqual(result.width, 4000)
        XCTAssertEqual(result.height, 600)
    }
}
