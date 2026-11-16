import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Smart crop final fixes: a Vision error has its own note and isn't cached; the box flip.
final class SmartCropFixTests: XCTestCase {
    /// A Vision error is not "nothing found": the note says detection was unavailable, and why.
    func testDetectionErrorsSayDetectionWasUnavailable() {
        struct Failure: LocalizedError { var errorDescription: String? { "Vision broke; badly" } }
        let subject = CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)
        let subjectFailed = FocusResolution.resolve(.subject, faces: { [] }, subject: { throw Failure() })
        XCTAssertNil(subjectFailed.rect)
        XCTAssertEqual(subjectFailed.note, "Subject detection unavailable: Vision broke, badly; cropped at the center")
        XCTAssertTrue(subjectFailed.detectionFailed)
        let facesFailed = FocusResolution.resolve(.faces, faces: { throw Failure() }, subject: { [subject] })
        XCTAssertEqual(facesFailed.rect, subject)
        XCTAssertEqual(facesFailed.note, "Face detection unavailable: Vision broke, badly; cropped around the subject")
        XCTAssertEqual(FocusResolution.resolve(.faces, faces: { throw Failure() }, subject: { throw Failure() }).note,
                       "Face detection unavailable: Vision broke, badly; cropped at the center")
        XCTAssertEqual(FocusResolution.resolve(.faces, faces: { [] }, subject: { throw Failure() }).note,
                       "No faces found; subject detection unavailable: Vision broke, badly; cropped at the center")
        XCTAssertFalse(FocusResolution.resolve(.subject, faces: { [] }, subject: { [] }).detectionFailed)
        // The estimate leaves these out like the other focus notes.
        XCTAssertEqual(FocusResolution.withoutFocusNotes("Other; " + (subjectFailed.note ?? "")), "Other")
        XCTAssertNil(FocusResolution.withoutFocusNotes("No faces found; subject detection unavailable: x; cropped at the center"))
    }

    /// A failed detection isn't cached: the next render asks Vision again.
    func testCacheDoesNotKeepAFailedDetection() throws {
        struct Failure: Error {}
        let cache = FocusCache()
        let detector = FakeVisionDetector(error: Failure())
        let context = FocusContext(detector: detector, cache: cache, sourceKey: "file|1|2")
        let image = TestImages.make(width: 400, height: 200)
        let crop = CropOptions(mode: .aspect(width: 1, height: 1), focus: .subject)
        let pipeline = Pipeline(steps: [PipelineStep(operation: .crop(crop))])
        for _ in 0..<2 { _ = try pipeline.apply(to: image, focus: context) }
        XCTAssertEqual(detector.recorded.count, 2)
    }

    /// Vision's boxes have a bottom-left origin; ours a top-left one.
    func testVisionBoxesAreFlippedToATopLeftOrigin() {
        XCTAssertEqual(SystemVisionDetector.topLeft(CGRect(x: 0.125, y: 0.25, width: 0.25, height: 0.5)),
                       CGRect(x: 0.125, y: 0.25, width: 0.25, height: 0.5))
        XCTAssertEqual(SystemVisionDetector.topLeft(CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)),
                       CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25))
        XCTAssertEqual(SystemVisionDetector.topLeft(CGRect(x: 0, y: 0, width: 1, height: 0.25)),
                       CGRect(x: 0, y: 0.75, width: 1, height: 0.25))
    }
}
