import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// A detector that returns fixed rectangles and records what it was asked.
final class FakeVisionDetector: VisionDetector, @unchecked Sendable {
    let faces: [CGRect]
    let subject: [CGRect]
    let error: Error?
    private let lock = NSLock()
    struct Call {
        let kind: String
        let width: Int
        let height: Int
    }

    private var calls: [Call] = []

    init(faces: [CGRect] = [], subject: [CGRect] = [], error: Error? = nil) {
        self.faces = faces
        self.subject = subject
        self.error = error
    }

    var recorded: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    private func record(_ kind: String, _ image: CGImage) throws {
        lock.lock()
        calls.append(Call(kind: kind, width: image.width, height: image.height))
        lock.unlock()
        if let error { throw error }
    }

    func faceRects(in image: CGImage) throws -> [CGRect] {
        try record("faces", image)
        return faces
    }

    func subjectRects(in image: CGImage) throws -> [CGRect] {
        try record("subject", image)
        return subject
    }
}

final class SmartCropTests: XCTestCase {
    // MARK: Geometry

    func testFocusedOriginCentresOnTheFocus() {
        let origin = Geometry.focusedOrigin(window: CGSize(width: 100, height: 100),
                                            focus: CGRect(x: 250, y: 40, width: 20, height: 20),
                                            container: CGSize(width: 400, height: 200))
        XCTAssertEqual(origin, CGPoint(x: 210, y: 0))
    }

    func testFocusedOriginClampsAtEdges() {
        let container = CGSize(width: 400, height: 200)
        let window = CGSize(width: 200, height: 200)
        XCTAssertEqual(Geometry.focusedOrigin(window: window, focus: CGRect(x: 0, y: 0, width: 10, height: 10),
                                              container: container), CGPoint(x: 0, y: 0))
        XCTAssertEqual(Geometry.focusedOrigin(window: window, focus: CGRect(x: 390, y: 190, width: 10, height: 10),
                                              container: container), CGPoint(x: 200, y: 0))
    }

    func testFocusLargerThanWindowKeepsTheFocusCentre() {
        // The focus (300 wide, centre x 200) is wider than the 100 px window: the window sits on its centre.
        let origin = Geometry.focusedOrigin(window: CGSize(width: 100, height: 100),
                                            focus: CGRect(x: 50, y: 0, width: 300, height: 100),
                                            container: CGSize(width: 400, height: 100))
        XCTAssertEqual(origin, CGPoint(x: 150, y: 0))
    }

    func testFocusedOriginIgnoresNonFiniteFocus() {
        let origin = Geometry.focusedOrigin(window: CGSize(width: 100, height: 100),
                                            focus: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                                            container: CGSize(width: 300, height: 100))
        XCTAssertEqual(origin, CGPoint(x: 100, y: 0))
    }

    func testCropRectUsesFocusOrAnchor() {
        let source = CGSize(width: 400, height: 200)
        let options = CropOptions(mode: .aspect(width: 1, height: 1), focus: .subject)
        XCTAssertEqual(Geometry.cropRect(source: source, options: options),
                       CGRect(x: 100, y: 0, width: 200, height: 200), "no focus found: centre")
        XCTAssertEqual(Geometry.cropRect(source: source, options: options,
                                         focus: CGRect(x: 360, y: 80, width: 40, height: 40)),
                       CGRect(x: 200, y: 0, width: 200, height: 200))
        XCTAssertEqual(Geometry.cropRect(source: source, options: CropOptions(anchor: .left)),
                       CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    func testFillCropSourceRectUsesAnchorAndFocus() {
        let source = CGSize(width: 400, height: 200)
        let scaled = CGSize(width: 200, height: 100)
        let crop = CGSize(width: 100, height: 100)
        XCTAssertEqual(Geometry.fillCropSourceRect(source: source, scaled: scaled, crop: crop),
                       CGRect(x: 100, y: 0, width: 200, height: 200))
        XCTAssertEqual(Geometry.fillCropSourceRect(source: source, scaled: scaled, crop: crop, anchor: .right),
                       CGRect(x: 200, y: 0, width: 200, height: 200))
        XCTAssertEqual(Geometry.fillCropSourceRect(source: source, scaled: scaled, crop: crop,
                                                   focus: CGRect(x: 0, y: 0, width: 50, height: 50)),
                       CGRect(x: 0, y: 0, width: 200, height: 200))
    }

}

final class SmartCropPipelineTests: XCTestCase {
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    // MARK: Fallbacks

    func testFacesUnionAndFallbacks() {
        // Binary fractions, so the union is exact.
        let face1 = CGRect(x: 0.125, y: 0.125, width: 0.125, height: 0.125)
        let face2 = CGRect(x: 0.5, y: 0.625, width: 0.25, height: 0.25)
        let subject = CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25)
        XCTAssertEqual(FocusResolution.resolve(.faces, faces: { [face1, face2] }, subject: { XCTFail("not asked"); return [] }),
                       FocusOutcome(rect: CGRect(x: 0.125, y: 0.125, width: 0.625, height: 0.75)))
        XCTAssertEqual(FocusResolution.resolve(.faces, faces: { [] }, subject: { [subject] }),
                       FocusOutcome(rect: subject, note: FocusResolution.facesToSubjectNote))
        XCTAssertEqual(FocusResolution.resolve(.faces, faces: { [] }, subject: { [] }),
                       FocusOutcome(rect: nil, note: FocusResolution.facesToCenterNote))
        XCTAssertEqual(FocusResolution.resolve(.subject, faces: { XCTFail("not asked"); return [] }, subject: { [] }),
                       FocusOutcome(rect: nil, note: FocusResolution.subjectToCenterNote))
        XCTAssertEqual(FocusResolution.resolve(.anchor(.top), faces: { XCTFail("not asked"); return [] },
                                               subject: { XCTFail("not asked"); return [] }), FocusOutcome(rect: nil))
    }

    func testDetectionErrorsCountAsNothingFound() {
        struct Failure: Error {}
        XCTAssertEqual(FocusResolution.resolve(.subject, faces: { [] }, subject: { throw Failure() }),
                       FocusOutcome(rect: nil, note: FocusResolution.subjectToCenterNote))
    }

    func testFocusNotesStayOutOfTheEstimate() {
        XCTAssertNil(FocusResolution.withoutFocusNotes(FocusResolution.facesToCenterNote))
        XCTAssertEqual(FocusResolution.withoutFocusNotes("No document edges found; " + FocusResolution.subjectToCenterNote),
                       "No document edges found")
        XCTAssertNil(FocusResolution.withoutFocusNotes(nil))
    }

    func testUnionDropsUnusableRects() {
        XCTAssertNil(FocusResolution.union([CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                                            CGRect(x: 2, y: 2, width: 1, height: 1), .zero]))
        XCTAssertEqual(FocusResolution.union([CGRect(x: -0.5, y: 0.5, width: 1, height: 1)]),
                       CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
    }

    // MARK: Pipeline

    private func cropPipeline(_ focus: CropFocus) -> Pipeline {
        Pipeline(steps: [PipelineStep(operation: .crop(CropOptions(mode: .aspect(width: 1, height: 1), focus: focus)))])
    }

    func testCropFollowsTheSubject() throws {
        // Left red, right blue; the subject is on the right.
        let image = TestImages.twoColor(width: 400, height: 200, left: red, right: blue)
        let detector = FakeVisionDetector(subject: [CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.2)])
        var notes: [String] = []
        let out = try cropPipeline(.subject).apply(to: image, focus: FocusContext(detector: detector), notes: &notes)
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(TestImages.pixel(of: out, x: 10, y: 100).blue, 255, accuracy: 2)
        XCTAssertEqual(notes, [])
    }

    func testFacesFallBackToSubjectWithANote() throws {
        let image = TestImages.twoColor(width: 400, height: 200, left: red, right: blue)
        let detector = FakeVisionDetector(subject: [CGRect(x: 0, y: 0, width: 0.1, height: 0.1)])
        var notes: [String] = []
        let out = try cropPipeline(.faces).apply(to: image, focus: FocusContext(detector: detector), notes: &notes)
        XCTAssertEqual(TestImages.pixel(of: out, x: 190, y: 100).red, 255, accuracy: 2)
        XCTAssertEqual(notes, [FocusResolution.facesToSubjectNote])
        XCTAssertEqual(detector.recorded.map(\.kind), ["faces", "subject"])
    }

    func testNothingFoundCropsTheCentreLikeToday() throws {
        let image = TestImages.noise(width: 300, height: 200)
        var notes: [String] = []
        let out = try cropPipeline(.subject).apply(to: image, focus: FocusContext(detector: FakeVisionDetector()),
                                                   notes: &notes)
        let centre = try cropPipeline(.anchor(.center)).apply(to: image)
        XCTAssertEqual(out.width, centre.width)
        XCTAssertEqual(TestImages.pixel(of: out, x: 7, y: 9).red, TestImages.pixel(of: centre, x: 7, y: 9).red)
        XCTAssertEqual(notes, [FocusResolution.subjectToCenterNote])
    }

    func testNoDetectionWhenNothingIsCropped() throws {
        let image = TestImages.make(width: 200, height: 200)
        let detector = FakeVisionDetector()
        var notes: [String] = []
        _ = try cropPipeline(.faces).apply(to: image, focus: FocusContext(detector: detector), notes: &notes)
        XCTAssertTrue(detector.recorded.isEmpty)
        XCTAssertEqual(notes, [])
    }

    func testDetectionRunsOnTheImageAtTheStepAndDownsampled() throws {
        // A 90° turn first: the crop sees a 1000 x 3000 image, which Vision gets at 1024 on the long side.
        let image = TestImages.make(width: 3000, height: 1000)
        let detector = FakeVisionDetector(subject: [CGRect(x: 0.4, y: 0.9, width: 0.2, height: 0.1)])
        let pipeline = Pipeline(steps: [
            PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw90))),
            PipelineStep(operation: .crop(CropOptions(mode: .aspect(width: 1, height: 1), focus: .subject)))
        ])
        var notes: [String] = []
        let out = try pipeline.apply(to: image, focus: FocusContext(detector: detector), notes: &notes)
        XCTAssertEqual(detector.recorded.first?.width, 341)
        XCTAssertEqual(detector.recorded.first?.height, 1024)
        XCTAssertEqual(out.width, 1000)
        XCTAssertEqual(out.height, 1000)
    }

    func testResizeFillAndCropFollowsTheFocus() throws {
        let image = TestImages.twoColor(width: 400, height: 200, left: red, right: blue)
        let detector = FakeVisionDetector(faces: [CGRect(x: 0.9, y: 0.4, width: 0.05, height: 0.1)])
        var options = ResizeOptions(mode: .exactSize(width: 100, height: 100, fill: .fillAndCrop))
        options.focus = .faces
        var notes: [String] = []
        let out = try Pipeline(steps: [PipelineStep(operation: .resize(options))])
            .apply(to: image, focus: FocusContext(detector: detector), notes: &notes)
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(TestImages.pixel(of: out, x: 5, y: 50).blue, 255, accuracy: 2)
        XCTAssertEqual(notes, [])

        options.focus = .anchor(.left)
        let left = try Pipeline(steps: [PipelineStep(operation: .resize(options))]).apply(to: image)
        XCTAssertEqual(TestImages.pixel(of: left, x: 95, y: 50).red, 255, accuracy: 2)
    }

    func testResizeWithoutFillNeverDetects() throws {
        let detector = FakeVisionDetector()
        var options = ResizeOptions(mode: .maxWidth(100))
        options.focus = .faces
        _ = try Pipeline(steps: [PipelineStep(operation: .resize(options))])
            .apply(to: TestImages.make(width: 400, height: 200), focus: FocusContext(detector: detector))
        XCTAssertTrue(detector.recorded.isEmpty)
    }

    func testCacheReusesDetectionForTheSameInput() throws {
        let image = TestImages.make(width: 400, height: 200)
        let detector = FakeVisionDetector(subject: [CGRect(x: 0.8, y: 0, width: 0.1, height: 0.1)])
        let cache = FocusCache()
        let context = FocusContext(detector: detector, cache: cache, sourceKey: "a.jpg|1|2")
        _ = try cropPipeline(.subject).apply(to: image, focus: context)
        _ = try cropPipeline(.subject).apply(to: image, focus: context)
        XCTAssertEqual(detector.recorded.count, 1)
        // A different step before the crop makes a different input.
        var changed = cropPipeline(.subject)
        changed.steps.insert(PipelineStep(operation: .adjust(AdjustOptions(exposure: 0.5))), at: 0)
        _ = try changed.apply(to: image, focus: context)
        XCTAssertEqual(detector.recorded.count, 2)
        XCTAssertEqual(cache.detectionCount, 2)
    }

    func testBatchPrepareAddsTheFallbackNote() throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 300, height: 200), to: url, type: .png)
        var options = ItemRunOptions()
        options.focus = FocusContext(detector: FakeVisionDetector())
        let prepared = try BatchRunner.prepare(url, pipeline: cropPipeline(.faces), assets: .empty,
                                               maxPixels: ImageLoader.defaultMaxPixels, options: options)
        XCTAssertEqual(prepared.notes, [FocusResolution.facesToCenterNote])
        XCTAssertEqual(prepared.image.width, 200)
    }

    func testPreviewUsesTheSameDetectionAndCachesIt() async throws {
        let dir = try TestImages.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.twoColor(width: 400, height: 200, left: red, right: blue), to: url, type: .png)
        let detector = FakeVisionDetector(subject: [CGRect(x: 0.9, y: 0.5, width: 0.05, height: 0.05)])
        let renderer = PreviewRenderer(detector: detector)
        let item = InputItem(source: url, relativeDirectory: "")
        for _ in 0..<2 {
            guard case .ready(let result) = await renderer.render(item: item, index: 0, pipeline: cropPipeline(.subject)) else {
                return XCTFail("preview failed")
            }
            XCTAssertEqual(TestImages.pixel(of: result.after, x: 5, y: 100).blue, 255, accuracy: 2)
        }
        XCTAssertEqual(detector.recorded.count, 1)
    }

}

final class SmartCropSavingTests: XCTestCase {
    // MARK: Saving

    func testCropFocusRoundTripsAndOldStepsKeepTheirAnchor() throws {
        for focus in [CropFocus.subject, .faces, .anchor(.bottomRight)] {
            let options = CropOptions(mode: .size(width: 10, height: 20), focus: focus)
            let data = try JSONEncoder().encode(options)
            XCTAssertEqual(try JSONDecoder().decode(CropOptions.self, from: data), options)
        }
        let old = Data(#"{"mode":{"aspect":{"width":1,"height":1}},"anchor":"top"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CropOptions.self, from: old).focus, .anchor(.top))
        let unknown = Data(#"{"mode":{"aspect":{"width":1,"height":1}},"anchor":"left","focus":"pets"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CropOptions.self, from: unknown).focus, .anchor(.left))
        // Older versions read the anchor: a detected focus writes the centre.
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(CropOptions(mode: .aspect(width: 1, height: 1),
                                                                               focus: .faces)), encoding: .utf8))
        XCTAssertTrue(json.contains(#""anchor":"center""#))
        XCTAssertTrue(json.contains(#""focus":"faces""#))
    }

    func testResizeFocusRoundTripsAndDefaultsToTheCentre() throws {
        var options = ResizeOptions(mode: .exactSize(width: 10, height: 10, fill: .fillAndCrop))
        options.focus = .subject
        XCTAssertEqual(try JSONDecoder().decode(ResizeOptions.self, from: JSONEncoder().encode(options)), options)
        let old = Data(#"{"mode":{"maxWidth":{"_0":100}},"allowEnlarge":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ResizeOptions.self, from: old).focus, .default)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .resize(options)),
                                        PipelineStep(operation: .crop(CropOptions(mode: .aspect(width: 4, height: 3),
                                                                                  focus: .faces)))])
        XCTAssertEqual(try JSONDecoder().decode(Pipeline.self, from: JSONEncoder().encode(pipeline)), pipeline)
    }

    func testSummariesNameTheFocus() {
        XCTAssertEqual(ImageOperation.crop(CropOptions(mode: .aspect(width: 1, height: 1), focus: .faces)).summary,
                       "1:1 · faces")
        var options = ResizeOptions(mode: .exactSize(width: 10, height: 10, fill: .fillAndCrop))
        XCTAssertFalse(ImageOperation.resize(options).summary.contains("subject"))
        options.focus = .subject
        XCTAssertTrue(ImageOperation.resize(options).summary.hasSuffix("· subject"))
    }

    // MARK: Vision

    func testVisionInputShrinksLargeImages() throws {
        let image = TestImages.make(width: 3000, height: 1500)
        let input = try XCTUnwrap(VisionInput.prepared(image))
        XCTAssertEqual(input.width, 1024)
        XCTAssertEqual(input.height, 512)
        let small = TestImages.make(width: 50, height: 40)
        XCTAssertTrue(VisionInput.prepared(small) === small)
    }

    func testSystemDetectorFindsASingleHighContrastObject() throws {
        // A black square on the right of a white image.
        guard let ctx = CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("context")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 440, y: 100, width: 100, height: 100))
        let image = try XCTUnwrap(ctx.makeImage())
        guard let rects = try? SystemVisionDetector().subjectRects(in: image), !rects.isEmpty,
              let union = FocusResolution.union(rects) else {
            throw XCTSkip("Vision saliency found nothing here")
        }
        XCTAssertGreaterThan(union.midX, 0.5, "the subject is on the right: \(rects)")
        XCTAssertTrue(try SystemVisionDetector().faceRects(in: image).isEmpty)
    }
}
