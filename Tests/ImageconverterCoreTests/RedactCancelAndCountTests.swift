import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Final fix wave of round 3: an item cancelled during text detection is cancelled (not unchecked), and the note
/// counts one line found on the copy and in tiles once.
final class RedactCancelAndCountTests: XCTestCase {
    func testCancellationDuringTextDetectionCancelsTheItem() {
        struct CancelledText: VisionDetector {
            func faceRects(in image: CGImage) throws -> [CGRect] { [] }
            func subjectRects(in image: CGImage) throws -> [CGRect] { [] }
            func textRects(in image: CGImage) throws -> [CGRect] { throw CancellationError() }
        }
        let found = Redaction.detect(.text, in: TestImages.make(width: 20, height: 20), detector: CancelledText())
        XCTAssertTrue(found.cancelled)
        XCTAssertNil(found.failure, "cancelled, not unchecked")
        let pipeline = Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions(target: .text)))])
        XCTAssertThrowsError(try pipeline.apply(to: TestImages.make(width: 20, height: 20),
                                                focus: FocusContext(detector: CancelledText()))) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
    }

    func testTheTileGateChecksCancellationAfterWaiting() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            var ran = false
            do { try TextTiles.gated { ran = true } } catch { return !ran && error is CancellationError }
            return false
        }
        let cancelledWithoutReading = await task.value
        XCTAssertTrue(cancelledWithoutReading)
        XCTAssertEqual(try TextTiles.gated { 7 }, 7, "not cancelled: the body runs")
    }

    func testTileAndCopyBoxesOfOneLineCountOnceAndAreAllRedacted() throws {
        // One line found on the whole-image copy, again in two overlapping tiles (once cut by a tile's edge, once
        // whole and slightly offset), and a second line elsewhere.
        let copy = CGRect(x: 0.10, y: 0.20, width: 0.60, height: 0.05)
        let tileCut = CGRect(x: 0.10, y: 0.201, width: 0.25, height: 0.048)
        let tileWhole = CGRect(x: 0.102, y: 0.199, width: 0.597, height: 0.052)
        let other = CGRect(x: 0.10, y: 0.70, width: 0.40, height: 0.05)
        XCTAssertEqual(TextBoxes.distinctCount([copy, tileCut, tileWhole, other]), 2)
        let detector = FakeVisionDetector(text: [copy, tileCut, tileWhole, other])
        var notes: [String] = []
        let image = TestImages.make(width: 400, height: 300)
        let step = PipelineStep(operation: .redact(RedactOptions(target: .text)))
        _ = try Pipeline(steps: [step]).apply(to: image, focus: FocusContext(detector: detector), notes: &notes)
        XCTAssertTrue(notes.contains(Redaction.note(faces: 0, text: 2)), "\(notes)")
        // Every box is still redacted: the pixel rects are those of all four boxes.
        let rects = Redaction.pixelRects([copy, tileCut, tileWhole, other], padding: 0,
                                         in: CGSize(width: 400, height: 300))
        XCTAssertEqual(rects.count, 4)
    }
}
