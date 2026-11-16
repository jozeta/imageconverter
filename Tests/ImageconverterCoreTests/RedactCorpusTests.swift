import CoreGraphics
import Foundation
import XCTest
@testable import ImageconverterCore

/// Real Vision on generated text images: every inked pixel of every legible text must end up inside a redacted
/// rect. Skipped when Vision finds no text at all (CI virtual machines).
final class RedactCorpusTests: XCTestCase {
    struct Outcome {
        let name: String
        let legible: Bool
        let coverages: [Double]
        let seconds: Double
        var covered: Bool { coverages.allSatisfy { $0 >= RedactCorpusTests.required } }
    }

    /// Anti-aliased edge pixels at the very end of a glyph may fall outside; 99.5 % of the ink must be inside.
    static let required = 0.995

    static func run(_ item: RedactCorpus.Case, detector: any VisionDetector = SystemVisionDetector()) -> Outcome {
        let image = RedactCorpus.image(item)
        let start = Date()
        let found = Redaction.detect(.text, in: image, detector: detector)
        let seconds = Date().timeIntervalSince(start)
        let rects = Redaction.pixelRects(found.text, padding: RedactOptions.defaultPadding,
                                         in: CGSize(width: image.width, height: image.height))
        let coverages = item.texts.map { RedactCorpus.coverage(of: $0, in: item, rects: rects) }
        return Outcome(name: item.name, legible: item.legible, coverages: coverages, seconds: seconds)
    }

    private func skipWithoutVision() throws {
        let probe = RedactCorpus.image(RedactCorpus.basics[0])
        let found = Redaction.detect(.text, in: probe, detector: SystemVisionDetector())
        try XCTSkipIf(found.failure != nil || found.text.isEmpty, "Vision found no text here (CI virtual machine?)")
    }

    func testEveryLegibleCorpusTextIsCovered() throws {
        try skipWithoutVision()
        var lines = ["| Case | Coverage | Covered | Seconds |", "|---|---|---|---|"]
        var misses: [String] = []
        for item in RedactCorpus.all {
            let outcome = Self.run(item)
            let coverage = outcome.coverages.map { String(format: "%.0f %%", $0 * 100) }.joined(separator: ", ")
            lines.append("| \(item.name)\(item.legible ? "" : " (not required)") | \(coverage) | "
                         + "\(outcome.covered ? "yes" : "NO") | \(String(format: "%.2f", outcome.seconds)) |")
            if item.legible, !outcome.covered { misses.append("\(item.name): \(coverage)") }
        }
        print(lines.joined(separator: "\n"))
        XCTAssertEqual(misses, [], "text left visible")
    }

    func testCoverageCheckSeesUncoveredText() {
        let item = RedactCorpus.basics[0]
        XCTAssertEqual(RedactCorpus.coverage(of: item.texts[0], in: item, rects: []), 0)
        let all = CGRect(x: 0, y: 0, width: item.width, height: item.height)
        XCTAssertEqual(RedactCorpus.coverage(of: item.texts[0], in: item, rects: [all]), 1)
    }

    func testTilesCoverLargeImagesWithOverlapAndFullSizeTiles() {
        XCTAssertEqual(TextTiles.tiles(width: 2048, height: 1500), [], "one Vision copy is enough")
        let tiles = TextTiles.tiles(width: 6000, height: 4000)
        XCTAssertEqual(TextTiles.origins(length: 6000, side: 2048, overlap: 256), [0, 1792, 3584, 3952])
        XCTAssertEqual(tiles.count, 4 * 3)
        XCTAssertTrue(tiles.allSatisfy { $0.width == 2048 && $0.height == 2048 })
        XCTAssertEqual(tiles.map(\.maxX).max(), 6000)
        XCTAssertEqual(tiles.map(\.maxY).max(), 4000)
        let narrow = TextTiles.tiles(width: 900, height: 5000)
        XCTAssertEqual(narrow.map(\.width), [900, 900, 900])
        XCTAssertEqual(narrow.map(\.minY), [0, 1792, 2952])
    }

    func testTileBoxesMapBackToTheImage() {
        let tile = CGRect(x: 2000, y: 1000, width: 2048, height: 2048)
        let box = TextTiles.imageBox(CGRect(x: 0.5, y: 0.25, width: 0.1, height: 0.05), tile: tile,
                                     width: 8000, height: 4000)
        XCTAssertEqual(box.minX * 8000, 2000 + 1024, accuracy: 0.001)
        XCTAssertEqual(box.minY * 4000, 1000 + 512, accuracy: 0.001)
        XCTAssertEqual(box.width * 8000, 204.8, accuracy: 0.001)
        XCTAssertEqual(box.height * 4000, 102.4, accuracy: 0.001)
        XCTAssertNil(TextTiles.bounds(of: []))
        XCTAssertNil(TextTiles.bounds(of: [CGPoint(x: Double.nan, y: 0)]))
        XCTAssertEqual(TextTiles.bounds(of: [CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.25, y: 0.75)]),
                       CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.5))
    }
}
