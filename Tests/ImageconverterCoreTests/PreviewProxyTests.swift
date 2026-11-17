import CoreGraphics
import Foundation
import XCTest
@testable import ImageconverterCore

/// Faster selection and preview: no delay on a selection change, a quick proxy for scale-invariant pipelines that
/// the exact render replaces, and one full decode shared by the preview and the size estimate.
final class PreviewProxyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func item(_ name: String = "a.png", width: Int = 1000, height: Int = 800) throws -> InputItem {
        let url = dir.appendingPathComponent(name)
        try TestImages.write(TestImages.noise(width: width, height: height), to: url, type: name.hasSuffix(".jpg") ? .jpeg : .png)
        return InputItem(source: url, relativeDirectory: "")
    }

    private func pipeline(_ operations: ImageOperation...) -> Pipeline {
        Pipeline(steps: operations.map { PipelineStep(operation: $0) }, output: .init(format: .png))
    }

    private var adjust: AdjustOptions {
        var options = AdjustOptions()
        options.exposure = 20
        options.contrast = 15
        return options
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: info)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// What the batch makes of `item`, fitted for display the way the preview fits it.
    private func batchFitted(_ item: InputItem, _ pipeline: Pipeline, displayMax: Int) throws -> CGImage {
        let prepared = try BatchRunner.prepare(item.source, pipeline: pipeline, assets: .empty,
                                               maxPixels: ImageLoader.defaultMaxPixels)
        return try XCTUnwrap(PreviewRenderer.fit(pipeline.matted(prepared.image, for: pipeline.output.format).image,
                                                 displayMax: displayMax))
    }

    // MARK: Timing

    func testSelectionRendersWithoutDebounce() async {
        XCTAssertEqual(PreviewTiming.previewDelay(selectionChanged: true), .zero)
        XCTAssertEqual(PreviewTiming.previewDelay(selectionChanged: false), .milliseconds(300))
        XCTAssertEqual(PreviewTiming.estimateDelay(selectionChanged: true), .zero)
        XCTAssertEqual(PreviewTiming.estimateDelay(selectionChanged: false), .milliseconds(400))

        // The injected sleeper sees exactly the delay; a zero delay doesn't sleep at all.
        let slept = Recorder<Duration>()
        let delivered = Recorder<Int>()
        await PreviewTiming.run(exactDelay: .zero, sleep: { await slept.add($0) }, proxy: nil,
                                exact: { 1 }, deliver: { value, _ in await delivered.add(value) })
        var sleeps = await slept.values
        XCTAssertEqual(sleeps, [])
        await PreviewTiming.run(exactDelay: .milliseconds(300), sleep: { await slept.add($0) }, proxy: nil,
                                exact: { 2 }, deliver: { value, _ in await delivered.add(value) })
        sleeps = await slept.values
        XCTAssertEqual(sleeps, [.milliseconds(300)])
        let values = await delivered.values
        XCTAssertEqual(values, [1, 2])
    }

    func testCancelledSleepSkipsTheExactRender() async {
        let delivered = Recorder<String>()
        await PreviewTiming.run(exactDelay: .milliseconds(300), sleep: { _ in throw CancellationError() },
                                proxy: { "proxy" }, exact: { "exact" },
                                deliver: { value, _ in await delivered.add(value) })
        // A slider still moving: the proxy shows, the exact render waits for the last edit.
        let values = await delivered.values
        XCTAssertEqual(values, ["proxy"])
    }

    // MARK: Which pipelines may use a proxy

    func testProxyUsedOnlyForScaleInvariant() async throws {
        var soften = AdjustOptions()
        soften.sharpness = -40
        var sharpen = AdjustOptions()
        sharpen.sharpness = 20
        var noise = AdjustOptions()
        noise.noiseReduction = 30
        var reduce = ColorOptions(profile: .sRGB)
        reduce.reduce.isEnabled = true
        var nearest = ResizeOptions(mode: .percent(50))
        nearest.resampling = .nearest
        var straighten = RotateFlipOptions()
        straighten.angle = 3

        XCTAssertTrue(Pipeline().isScaleInvariant)
        XCTAssertTrue(pipeline(.adjust(adjust)).isScaleInvariant)
        XCTAssertTrue(pipeline(.adjust(soften)).isScaleInvariant, "Soften's radius is a fraction of the image")
        XCTAssertTrue(pipeline(.colorProfile(ColorOptions(profile: .displayP3))).isScaleInvariant)
        XCTAssertTrue(pipeline(.rotateFlip(RotateFlipOptions(rotation: .cw90, flipHorizontal: true))).isScaleInvariant)
        XCTAssertTrue(pipeline(.resize(ResizeOptions(mode: .percent(50))), .adjust(adjust)).isScaleInvariant)
        XCTAssertTrue(pipeline(.resize(ResizeOptions(mode: .longestEdge(2048)))).isScaleInvariant)
        XCTAssertTrue(pipeline(.resize(ResizeOptions(mode: .fitBox(width: 800, height: 600)))).isScaleInvariant)

        XCTAssertFalse(pipeline(.adjust(sharpen)).isScaleInvariant, "Sharpen's radius is in pixels")
        XCTAssertFalse(pipeline(.adjust(noise)).isScaleInvariant)
        XCTAssertFalse(pipeline(.colorProfile(reduce)).isScaleInvariant)
        XCTAssertFalse(pipeline(.rotateFlip(straighten)).isScaleInvariant)
        XCTAssertFalse(pipeline(.resize(nearest)).isScaleInvariant)
        XCTAssertFalse(pipeline(.resize(ResizeOptions(mode: .exactSize(width: 300, height: 300, fill: .fitAndPad))))
            .isScaleInvariant)
        XCTAssertFalse(pipeline(.resize(ResizeOptions(mode: .exactSize(width: 300, height: 300, fill: .fillAndCrop))))
            .isScaleInvariant)
        XCTAssertFalse(pipeline(.resize(ResizeOptions(mode: .mlEnlarge(factor: 2)))).isScaleInvariant)
        XCTAssertFalse(pipeline(.crop(CropOptions())).isScaleInvariant)
        XCTAssertFalse(pipeline(.canvas(CanvasOptions())).isScaleInvariant)
        XCTAssertFalse(pipeline(.perspective(PerspectiveOptions())).isScaleInvariant)
        XCTAssertFalse(pipeline(.trim(TrimOptions())).isScaleInvariant)
        XCTAssertFalse(pipeline(.watermark(WatermarkOptions())).isScaleInvariant)
        XCTAssertFalse(pipeline(.redact(RedactOptions())).isScaleInvariant)
        XCTAssertFalse(pipeline(.condition(ConditionalStep())).isScaleInvariant)
        // A disabled step doesn't count.
        var off = pipeline(.crop(CropOptions()), .adjust(adjust))
        off.steps[0].isEnabled = false
        XCTAssertTrue(off.isScaleInvariant)

        let renderer = PreviewRenderer(displayMax: 200, proxyMinimum: 200)
        let source = try item()
        let invariant = await renderer.renderProxy(item: source, index: 0, pipeline: pipeline(.adjust(adjust)))
        XCTAssertEqual(invariant?.isProxy, true)
        let crop = pipeline(.crop(CropOptions(mode: .size(width: 400, height: 300))))
        let none = await renderer.renderProxy(item: source, index: 0, pipeline: crop)
        XCTAssertNil(none, "A pixel-unit step never gets a proxy")
        // A source not much larger than the display gets no proxy either: the exact render is as quick.
        let small = try item("small.png", width: 300, height: 200)
        let tooSmall = await renderer.renderProxy(item: small, index: 0, pipeline: pipeline(.adjust(adjust)))
        XCTAssertNil(tooSmall)
    }

    func testProxyDecodeSizes() {
        // At least the display size; a JPEG decodes cheaply only at source / 2^k, so it is rounded up to one.
        XCTAssertEqual(PreviewProxy.decodeLongSide(sourceLongSide: 8000, target: 1600, jpeg: true), 2000)
        XCTAssertEqual(PreviewProxy.decodeLongSide(sourceLongSide: 8000, target: 1600, jpeg: false), 1600)
        XCTAssertEqual(PreviewProxy.decodeLongSide(sourceLongSide: 4000, target: 1600, jpeg: true), 2000)
        XCTAssertEqual(PreviewProxy.decodeLongSide(sourceLongSide: 6001, target: 1600, jpeg: true), 3001)
        // No proxy unless it is at most half the source.
        XCTAssertNil(PreviewProxy.decodeLongSide(sourceLongSide: 3000, target: 1600, jpeg: true))
        XCTAssertNil(PreviewProxy.decodeLongSide(sourceLongSide: 3000, target: 1600, jpeg: false))
        XCTAssertEqual(PreviewRenderer.proxyMinimumLongSide, 1600)
    }

    // MARK: The proxy is only a stand-in

    func testProxyNeverFinalForPixelUnitSteps() async throws {
        // Review Focus 1: the settled preview of a pixel-unit pipeline is the batch result fitted for display.
        let source = try item()
        let crop = pipeline(.crop(CropOptions(mode: .size(width: 400, height: 300))), .adjust(adjust))
        let renderer = PreviewRenderer(displayMax: 200, proxyMinimum: 200)
        let shown = Recorder<PreviewResult>()
        await PreviewTiming.run(exactDelay: .zero, proxy: { await renderer.renderProxy(item: source, index: 0, pipeline: crop) },
                                exact: {
                                    guard case .ready(let result) = await renderer.render(item: source, index: 0,
                                                                                         pipeline: crop) else { return nil }
                                    return result
                                }, deliver: { result, _ in await shown.add(result) })
        let results = await shown.values
        XCTAssertEqual(results.count, 1, "No proxy for a crop in pixels")
        let final = try XCTUnwrap(results.last)
        XCTAssertFalse(final.isProxy)
        let expected = try batchFitted(source, crop, displayMax: 200)
        XCTAssertEqual(final.after.width, expected.width)
        XCTAssertEqual(final.after.height, expected.height)
        XCTAssertEqual(rgba(final.after), rgba(expected))
        XCTAssertEqual(final.outputSize.0, 400)
    }

    func testProxyFollowedByExactRender() async throws {
        let source = try item()
        let resize = pipeline(.resize(ResizeOptions(mode: .percent(50))), .adjust(adjust))
        let renderer = PreviewRenderer(displayMax: 200, proxyMinimum: 200)
        let shown = Recorder<PreviewResult>()
        let finals = Recorder<Bool>()
        await PreviewTiming.run(exactDelay: .zero, proxy: { await renderer.renderProxy(item: source, index: 0, pipeline: resize) },
                                exact: {
                                    guard case .ready(let result) = await renderer.render(item: source, index: 0,
                                                                                         pipeline: resize) else { return nil }
                                    return result
                                }, deliver: { result, final in
                                    await shown.add(result)
                                    await finals.add(final)
                                })
        let results = await shown.values
        let flags = await finals.values
        XCTAssertEqual(results.map(\.isProxy), [true, false])
        XCTAssertEqual(flags, [false, true])
        let proxy = results[0]
        let exact = results[1]
        // The proxy says what the batch would make (full-size numbers) and fits the display like the exact one.
        XCTAssertEqual(proxy.outputSize.0, 500)
        XCTAssertEqual(proxy.outputSize.1, 400)
        XCTAssertEqual(proxy.sourceSize.0, 1000)
        XCTAssertEqual(proxy.outputName, exact.outputName)
        XCTAssertEqual(proxy.after.width, exact.after.width)
        XCTAssertEqual(proxy.after.height, exact.after.height)
        XCTAssertNil(proxy.altTextRequest)
        // The exact render is the batch's result fitted for display.
        let expected = try batchFitted(source, resize, displayMax: 200)
        XCTAssertEqual(rgba(exact.after), rgba(expected))
    }

    func testProxyOfALargeJPEGDecodesSmallAndKeepsTheFullDecodeForLater() async throws {
        let source = try item("big.jpg", width: 1600, height: 1200)
        let renderer = PreviewRenderer(displayMax: 300, proxyMinimum: 300)
        let rendered = await renderer.renderProxy(item: source, index: 0, pipeline: pipeline(.adjust(adjust)))
        let proxy = try XCTUnwrap(rendered)
        XCTAssertTrue(proxy.isProxy)
        XCTAssertEqual(proxy.after.width, 300)
        XCTAssertEqual(proxy.sourceSize.0, 1600)
        // The proxy didn't decode the full image; the exact render does, once.
        var count = await renderer.decodeCount
        XCTAssertEqual(count, 0)
        _ = await renderer.render(item: source, index: 0, pipeline: pipeline(.adjust(adjust)))
        _ = await renderer.renderProxy(item: source, index: 0, pipeline: pipeline(.adjust(adjust)))
        count = await renderer.decodeCount
        XCTAssertEqual(count, 1)
    }

    // MARK: One decode for the preview and the estimate

    func testEstimateReusesPreviewDecode() async throws {
        let source = try item()
        let renderer = PreviewRenderer(displayMax: 200)
        let plain = pipeline(.adjust(adjust))
        _ = await renderer.render(item: source, index: 0, pipeline: plain)
        let estimate = try SizeEstimator.render(item: source, pipeline: plain, caches: renderer.caches)
        var count = renderer.caches.sources.decodeCount
        XCTAssertEqual(count, 1, "The estimate takes the preview's decoded source")
        XCTAssertEqual(estimate.original?.width, 1000)

        // A shrinking first step: the estimate decodes downsampled once, and the full original for the comparison
        // view comes from the preview's decode.
        let shrink = pipeline(.resize(ResizeOptions(mode: .percent(25))))
        let hinted = try SizeEstimator.render(item: source, pipeline: shrink, caches: renderer.caches)
        count = renderer.caches.sources.decodeCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(hinted.original?.width, 1000)

        // Matches what is written, as before.
        let out = dir.appendingPathComponent("out", isDirectory: true)
        let report = await BatchRunner.run([source], pipeline: plain, mode: .newFolder(out))
        let written = try XCTUnwrap(report.written.first)
        XCTAssertEqual(try written.resourceValues(forKeys: [.fileSizeKey]).fileSize, estimate.bytes)
    }

    func testConcurrentPreviewAndEstimateShareOneDecode() async throws {
        let source = try item()
        let renderer = PreviewRenderer(displayMax: 200)
        let caches = renderer.caches
        let plain = pipeline(.adjust(adjust))
        async let preview = renderer.render(item: source, index: 0, pipeline: plain)
        async let estimate = Task.detached { try SizeEstimator.render(item: source, pipeline: plain, caches: caches) }.value
        _ = await preview
        _ = try await estimate
        XCTAssertEqual(caches.sources.decodeCount, 1)
    }

    func testSourceCacheFollowsTheFileAndPurge() async throws {
        let source = try item()
        let renderer = PreviewRenderer(displayMax: 200)
        _ = await renderer.render(item: source, index: 0, pipeline: Pipeline())
        await renderer.purge()
        _ = await renderer.render(item: source, index: 0, pipeline: Pipeline())
        XCTAssertEqual(renderer.caches.sources.decodeCount, 2)
        try TestImages.write(TestImages.make(width: 320, height: 200), to: source.source, type: .png)
        let estimate = try SizeEstimator.render(item: source, pipeline: Pipeline(), caches: renderer.caches)
        XCTAssertEqual(estimate.original?.width, 320)
        XCTAssertEqual(renderer.caches.sources.decodeCount, 3)
    }
}

/// Collects values from async closures in order.
private actor Recorder<Value> {
    private(set) var values: [Value] = []
    func add(_ value: Value) { values.append(value) }
}
