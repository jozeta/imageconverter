import CoreGraphics
@testable import ImageconverterCore
import XCTest

/// ML enlarge review fixes: colour spaces, tiling bounds, one path, timeouts, wording and jobs.
final class MLEnlargeFixTests: XCTestCase {
    private func image(space: CFString, bits: Int, float: Bool = false) throws -> CGImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: space))
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if float { info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: bits, bytesPerRow: 0,
                                          space: colorSpace, bitmapInfo: info))
        ctx.setFillColor(red: 0.6, green: 0.3, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func enlarge(_ image: CGImage, notes: inout [String]) throws -> CGImage {
        try MLEnlarge.enlarge(image, factor: 2, scaler: FakeScaler(), notes: &notes)
    }

    private func mlPipeline() -> Pipeline {
        Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .mlEnlarge(factor: 2))))])
    }

    // MARK: Colour spaces

    func testFloatExtendedLinearSourceIsEnlargedInStandardRangeSRGB() throws {
        var notes: [String] = []
        let result = try enlarge(try image(space: CGColorSpace.extendedLinearSRGB, bits: 32, float: true), notes: &notes)
        XCTAssertEqual(result.width, 24)
        XCTAssertEqual(result.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(notes, [MLEnlarge.standardRangeNote])
    }

    func testSixteenBitLinearSourceGoesToSRGB() throws {
        var notes: [String] = []
        let result = try enlarge(try image(space: CGColorSpace.linearSRGB, bits: 16), notes: &notes)
        XCTAssertEqual(result.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(notes, [MLEnlarge.standardRangeNote])
    }

    func testExtendedDisplayP3BecomesDisplayP3() throws {
        var notes: [String] = []
        let result = try enlarge(try image(space: CGColorSpace.extendedDisplayP3, bits: 32, float: true), notes: &notes)
        XCTAssertEqual(result.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(notes, [MLEnlarge.standardRangeNote])
    }

    // MARK: Tiling

    func testOverlapIsCappedSoOnlyNeighboursOverlap() {
        let wide = MLEnlargeTiling(maxTile: 129, overlap: 64)
        XCTAssertEqual(wide.overlap, 43)
        let tilings = [wide, MLEnlargeTiling(maxTile: 64, overlap: 64), MLEnlargeTiling(maxTile: 3, overlap: 5),
                       MLEnlargeTiling(maxTile: 100, overlap: 33), MLEnlargeTiling(maxTile: 1920, overlap: 900)]
        for tiling in tilings {
            for length in [1, 2, 3, 64, 129, 130, 300, 301, 777, 2000, 5000] {
                let spans = tiling.spans(length: length)
                XCTAssertEqual(spans.last?.end, length, "\(tiling) \(length)")
                for index in spans.indices.dropFirst(2) {
                    XCTAssertGreaterThanOrEqual(spans[index].start, spans[index - 2].end, "\(tiling) \(length)")
                }
                for span in spans { XCTAssertLessThanOrEqual(span.length, tiling.maxTile) }
            }
        }
    }

    // MARK: One path, timeouts

    func testImageOpsResizeNeverPlainScalesAnMLStep() {
        XCTAssertThrowsError(try ImageOps.resize(TestImages.make(width: 10, height: 10),
                                                 ResizeOptions(mode: .mlEnlarge(factor: 2))))
    }

    func testAModelThatDoesNotAnswerTimesOut() {
        XCTAssertThrowsError(try MLEnlarge.waitForModel(timeout: 0.05) { _ in }) {
            XCTAssertEqual($0 as? ConversionError, .mlEnlargeNoResponse)
        }
        XCTAssertEqual(ConversionError.mlEnlargeNoResponse.reason, "Not enlarged: the enlargement model didn't respond")
        XCTAssertThrowsError(try MLEnlarge.waitForModel(timeout: 1) { finished in
            finished(CocoaError(.featureUnsupported))
        })
        XCTAssertNoThrow(try MLEnlarge.waitForModel(timeout: 1) { finished in
            DispatchQueue.global().async { finished(nil) }
        })
    }

    func testANonRespondingModelWritesNothing() async throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 20, height: 20), to: url, type: .png)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        let report = await BatchRunner.run([InputItem(source: url, relativeDirectory: "")], pipeline: mlPipeline(),
                                           mode: .newFolder(out),
                                           enlarger: FakeScaler(failure: ConversionError.mlEnlargeNoResponse))
        XCTAssertEqual(report.written, [])
        XCTAssertEqual(report.failures.map(\.reason), ["Not enlarged: the enlargement model didn't respond"])
        XCTAssertEqual(report.failures.map(\.awaitsModelDownload), [false])
        let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        XCTAssertEqual(left, [], "no partial or temporary output")
    }

    // MARK: Wording

    func testInAppWordingAndHiddenMode() {
        XCTAssertEqual(MLEnlargeAvailability.downloadRequired.refusal(inApp: true),
                       "Not enlarged: Apple's enlargement model isn't downloaded. Download it in the Resize step.")
        XCTAssertTrue(MLEnlargeAvailability.downloadRequired.refusal.contains("Open imageconverter"))
        XCTAssertTrue(SystemSuperResolution.inApp.speaksFromApp)
        XCTAssertFalse(SystemSuperResolution.shared.speaksFromApp)
        var notes: [String] = []
        XCTAssertThrowsError(try MLEnlarge.enlarge(TestImages.make(width: 4, height: 4), factor: 2,
                                                   scaler: FakeScaler(status: .downloadRequired, speaksFromApp: true),
                                                   notes: &notes)) {
            XCTAssertEqual(($0 as? ConversionError)?.reason, MLEnlargeAvailability.downloadRequired.refusal(inApp: true))
        }
        XCTAssertFalse(MLEnlargeAvailability.unsupportedHardware.offersMode)
        XCTAssertFalse(MLEnlargeAvailability.unsupportedOS.offersMode)
        XCTAssertTrue(MLEnlargeAvailability.downloadRequired.offersMode)
        XCTAssertTrue(MLEnlargeAvailability.downloading(progress: 0.2).awaitsDownload)
        XCTAssertFalse(MLEnlargeAvailability.unsupportedHardware.awaitsDownload)
    }

    /// A build without the macOS 26 SDK running on macOS 26 or later says the build can't, not "needs macOS 26".
    func testABuildWithoutTheSDKSaysSoOnMacOS26() {
        XCTAssertEqual(SystemSuperResolution.fallback(onMacOS26: false), .unsupportedOS)
        XCTAssertEqual(SystemSuperResolution.fallback(onMacOS26: true),
                       SystemSuperResolution.isCompiledIn ? .unsupportedOS : .notInThisBuild)
        XCTAssertEqual(MLEnlargeAvailability.notInThisBuild.refusal,
                       "Not enlarged: this build of imageconverter can't enlarge with machine learning.")
        XCTAssertEqual(MLEnlargeAvailability.notInThisBuild.refusal(inApp: true),
                       MLEnlargeAvailability.notInThisBuild.refusal)
        XCTAssertEqual(MLEnlargeAvailability.notInThisBuild.editorMessage,
                       "This build of imageconverter can't enlarge with machine learning.")
        XCTAssertFalse(MLEnlargeAvailability.notInThisBuild.offersMode)
        XCTAssertFalse(MLEnlargeAvailability.notInThisBuild.awaitsDownload)
        let onMacOS26 = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        if !SystemSuperResolution.isCompiledIn, SystemSuperResolution.simulatedStatus == nil {
            XCTAssertEqual(SystemSuperResolution.shared.availability(), onMacOS26 ? .notInThisBuild : .unsupportedOS)
        }
    }

    // MARK: Jobs

    func testJobsDontCountWaitingForTheModelAsAnAttempt() async throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 20, height: 20), to: url, type: .png)
        let fingerprint = try XCTUnwrap(FileFingerprint.of(url))
        let report = await BatchRunner.run([InputItem(source: url, relativeDirectory: "")], pipeline: mlPipeline(),
                                           mode: .newFolder(dir.appendingPathComponent("out", isDirectory: true)),
                                           enlarger: FakeScaler(status: .downloadRequired))
        XCTAssertEqual(report.failures.map(\.awaitsModelDownload), [true])
        var ledger = ProcessedLedger()
        for _ in 0..<5 { _ = JobRunner.update(&ledger, with: report, fingerprints: [url: fingerprint]) }
        XCTAssertEqual(ledger.failures(of: fingerprint), 0)
        XCTAssertFalse(ledger.isSettled(fingerprint), "still a candidate for when the model is there")

        // Any other failure still counts.
        var other = report
        other.failures[0].awaitsModelDownload = false
        _ = JobRunner.update(&ledger, with: other, fingerprints: [url: fingerprint])
        XCTAssertEqual(ledger.failures(of: fingerprint), 1)
    }
}
