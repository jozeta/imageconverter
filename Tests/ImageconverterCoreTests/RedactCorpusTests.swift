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
        /// Per padding in `paddings`, the coverage of each text.
        let coverages: [Double: [Double]]
        let seconds: Double
        func covered(at padding: Double) -> Bool {
            (coverages[padding] ?? []).allSatisfy { $0 >= RedactCorpusTests.required(at: padding) }
        }
        var covered: Bool { RedactCorpusTests.paddings.allSatisfy(covered(at:)) }
    }

    /// Anti-aliased edge pixels at the very end of a glyph may fall outside: 99.5 % of the ink must be inside, 98 %
    /// without padding (Vision's boxes hug the glyphs; measured lowest: 98.7 %, a single "7").
    static func required(at padding: Double) -> Double { padding > 0 ? 0.995 : 0.98 }
    /// No padding, the default and a generous one: Vision's own boxes must cover the ink without help.
    static let paddings = [0, RedactOptions.defaultPadding, 30]

    static func run(_ item: RedactCorpus.Case, detector: any VisionDetector = SystemVisionDetector()) -> Outcome {
        let image = RedactCorpus.image(item)
        let start = Date()
        let found = Redaction.detect(.text, in: image, detector: detector)
        let seconds = Date().timeIntervalSince(start)
        var coverages: [Double: [Double]] = [:]
        for padding in paddings {
            let rects = Redaction.pixelRects(found.text, padding: padding,
                                             in: CGSize(width: image.width, height: image.height))
            coverages[padding] = item.texts.map { RedactCorpus.coverage(of: $0, in: item, rects: rects) }
        }
        return Outcome(name: item.name, legible: item.legible, coverages: coverages, seconds: seconds)
    }

    private func skipWithoutVision() throws {
        let probe = RedactCorpus.image(RedactCorpus.basics[0])
        let found = Redaction.detect(.text, in: probe, detector: SystemVisionDetector())
        try XCTSkipIf(found.failure != nil || found.text.isEmpty, "Vision found no text here (CI virtual machine?)")
    }

    func testEveryLegibleCorpusTextIsCovered() throws {
        try skipWithoutVision()
        var lines = ["| Case | Lowest coverage at padding 0 / 15 / 30 % | Covered | Seconds |", "|---|---|---|---|"]
        var misses: [String] = []
        for item in RedactCorpus.all {
            let outcome = Self.run(item)
            let lowest = Self.paddings.map { padding in
                String(format: "%.1f %%", (outcome.coverages[padding]?.min() ?? 1) * 100)
            }.joined(separator: " / ")
            lines.append("| \(item.name)\(item.legible ? "" : " (not required)") | \(lowest) | "
                         + "\(outcome.covered ? "yes" : "NO") | \(String(format: "%.2f", outcome.seconds)) |")
            if item.legible, !outcome.covered { misses.append("\(item.name): \(lowest)") }
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
        XCTAssertEqual(TextTiles.side, 896)
        XCTAssertEqual(TextTiles.overlap, 192)
        XCTAssertEqual(TextTiles.tiles(width: 2048, height: 1500), [], "one Vision copy is enough")
        XCTAssertEqual(TextTiles.origins(length: 6000, side: 2048, overlap: 256), [0, 1792, 3584, 3952])
        XCTAssertEqual(TextTiles.origins(length: 6000, side: 896, overlap: 192),
                       [0, 704, 1408, 2112, 2816, 3520, 4224, 4928, 5104])
        let tiles = TextTiles.tiles(width: 6000, height: 4000)
        XCTAssertEqual(tiles.count, 9 * 6)
        XCTAssertTrue(tiles.allSatisfy { $0.width == 896 && $0.height == 896 })
        XCTAssertEqual(tiles.map(\.maxX).max(), 6000)
        XCTAssertEqual(tiles.map(\.maxY).max(), 4000)
        let narrow = TextTiles.tiles(width: 800, height: 3000)
        XCTAssertEqual(Set(narrow.map(\.width)), [800])
        XCTAssertEqual(narrow.map(\.minY), [0, 704, 1408, 2104])
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

    /// Tile reading is gated process-wide: 8 batch workers reading tiles at once took 41 s for 8 large images, at
    /// most 2 at a time about 18 s.
    func testAtMostTwoImagesReadTilesAtOnce() {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var inside = 0
            var most = 0
            func change(_ delta: Int) {
                lock.lock()
                inside += delta
                most = max(most, inside)
                lock.unlock()
            }
        }
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            try? TextTiles.gated {
                counter.change(1)
                Thread.sleep(forTimeInterval: 0.05)
                counter.change(-1)
            }
        }
        XCTAssertEqual(TextTiles.concurrentImages, 2)
        XCTAssertEqual(counter.most, 2)
    }
}
