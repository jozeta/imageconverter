import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// The facts the new checks read from real files: header only, and only what the conditions need.
final class ConditionFactsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNameFolderAndFileDates() throws {
        let folder = root.appendingPathComponent("Holiday 2024", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("IMG_0042.JPG")
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .jpeg)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: url.path)
        let facts = try XCTUnwrap(ItemFacts.read(url))
        XCTAssertEqual(facts.fileName, "IMG_0042")
        XCTAssertEqual(facts.fileExtension, "jpg")
        XCTAssertEqual(facts.folderPath, folder.path)
        XCTAssertEqual(facts.created, created)
        XCTAssertEqual(facts.modified, created)
        XCTAssertNil(facts.dateTaken, "no EXIF or XMP date: no date taken (the file dates don't count)")
        XCTAssertTrue(Condition(.fileExtension(["jpeg"])).matches(facts))
        XCTAssertTrue(Condition(.folder(contains: "holiday")).matches(facts))
        XCTAssertTrue(Condition(.date(.created, .inYear(CalendarDay(created).year))).matches(facts))
        XCTAssertTrue(Condition(.date(.taken, .exists), negated: true).matches(facts))
    }

    func testDateTakenFromEXIFThenXMP() throws {
        let exif = try MetadataTestSupport.source(root.appendingPathComponent("exif.jpg"), properties: [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2024:03:10 14:30:00"],
        ])
        let taken = try XCTUnwrap(ItemFacts.read(exif)?.dateTaken)
        XCTAssertEqual(CalendarDay(taken), CalendarDay(year: 2024, month: 3, day: 10))
        XCTAssertEqual(CalendarDay.calendar.component(.hour, from: taken), 14, "the wall clock as written")

        let xmp = try MetadataTestSupport.source(root.appendingPathComponent("xmp.jpg"),
                                                 xmp: [("photoshop:DateCreated", "2023-07-01T08:00:00")])
        XCTAssertEqual(ItemFacts.read(xmp).flatMap(\.dateTaken).map { CalendarDay($0) },
                       CalendarDay(year: 2023, month: 7, day: 1))
    }

    func testMetadataFields() throws {
        let url = try MetadataTestSupport.source(root.appendingPathComponent("meta.jpg"), properties: [
            // ImageIO keeps a JPEG's TIFF artist as IPTC Byline; either way it is the artist.
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFArtist as String: "Johan"],
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifISOSpeedRatings as String: [1600],
                                                       kCGImagePropertyExifFNumber as String: 2.8,
                                                       kCGImagePropertyExifExposureTime as String: 0.004,
                                                       kCGImagePropertyExifFocalLength as String: 50,
                                                       kCGImagePropertyExifLensModel as String: "50mm F1.8"],
        ])
        // ImageIO's JPEG writer moves TIFF fields into XMP when IPTC is written too: IPTC goes in its own file.
        let iptc = try MetadataTestSupport.source(root.appendingPathComponent("iptc.jpg"), properties: [
            kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCKeywords as String: ["Travel", "Family"],
                                                       kCGImagePropertyIPTCCity as String: "Stockholm"],
        ])
        let facts = try XCTUnwrap(ItemFacts.read(url))
        let iptcFacts = try XCTUnwrap(ItemFacts.read(iptc))
        XCTAssertEqual(facts.values(of: .named(.artist)), ["Johan"])
        XCTAssertEqual(facts.values(of: .named(.lens)), ["50mm F1.8"])
        XCTAssertEqual(iptcFacts.values(of: .named(.keywords)), ["Travel", "Family"])
        XCTAssertEqual(iptcFacts.values(of: .custom(.iptc, "City")), ["Stockholm"])
        XCTAssertEqual(facts.values(of: .custom(.exif, "LensModel")), ["50mm F1.8"])
        // A field only in XMP is read when a condition needs XMP.
        let titled = try MetadataTestSupport.source(root.appendingPathComponent("title.png"), type: .png,
                                                    xmp: [("dc:title", "Sunset"), ("photoshop:City", "Oslo")])
        XCTAssertEqual(ItemFacts.read(titled)?.values(of: .custom(.xmp, "photoshop:City")), ["Oslo"])
        XCTAssertEqual(ItemFacts.read(titled, needs: [])?.values(of: .custom(.xmp, "photoshop:City")), [])
        XCTAssertTrue(ItemFacts.read(titled)?.values(of: .named(.title)).contains("Sunset") ?? false)
        for (test, expected) in [(MetadataTest(.named(.iso), .greaterThan, "800"), true),
                                 (MetadataTest(.named(.aperture), .equals, "2.8"), true),
                                 (MetadataTest(.named(.shutterSpeed), .equals, "1/250"), true),
                                 (MetadataTest(.named(.focalLength), .atLeast, "85"), false),
                                 (MetadataTest(.named(.copyright), .missing), true)] {
            XCTAssertEqual(Condition(.metadata(test)).matches(facts), expected, "\(test)")
        }
    }

    func testImageFacts() throws {
        let wide = root.appendingPathComponent("wide.png")
        try TestImages.write(TestImages.displayP3(width: 30, height: 30), to: wide, type: .png,
                             properties: [kCGImagePropertyDPIWidth as String: 300, kCGImagePropertyDPIHeight as String: 300])
        let facts = try XCTUnwrap(ItemFacts.read(wide))
        XCTAssertEqual(facts.bitsPerComponent, 16)
        XCTAssertTrue(Condition(.bitDepth(.sixteen)).matches(facts))
        XCTAssertTrue(Condition(.colorSpace(.displayP3)).matches(facts), "\(String(describing: facts.profileName))")
        XCTAssertTrue(Condition(.hasProfile).matches(facts))
        XCTAssertTrue(Condition(.dpi(.atLeast, 300)).matches(facts))
        XCTAssertTrue(Condition(.aspectRatio(.square)).matches(facts))

        let gray = root.appendingPathComponent("gray.png")
        let space = CGColorSpaceCreateDeviceGray()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        try TestImages.write(try XCTUnwrap(ctx.makeImage()), to: gray, type: .png)
        XCTAssertTrue(Condition(.colorSpace(.gray)).matches(try XCTUnwrap(ItemFacts.read(gray))))
        XCTAssertTrue(Condition(.bitDepth(.eight)).matches(try XCTUnwrap(ItemFacts.read(gray))))

        let rotated = root.appendingPathComponent("rotated.jpg")
        try TestImages.write(TestImages.make(width: 40, height: 20), to: rotated, type: .jpeg,
                             properties: [kCGImagePropertyOrientation as String: 6])
        XCTAssertTrue(Condition(.isRotated).matches(try XCTUnwrap(ItemFacts.read(rotated))))
        XCTAssertFalse(Condition(.isRotated).matches(try XCTUnwrap(ItemFacts.read(wide))))
    }

    func testFrameCountOnlyWhenNeeded() throws {
        let gif = root.appendingPathComponent("anim.gif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 3, nil))
        for _ in 0..<3 { CGImageDestinationAddImage(dest, TestImages.make(width: 10, height: 10), nil) }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertEqual(ItemFacts.read(gif)?.frameCount, 3)
        XCTAssertEqual(ItemFacts.read(gif, needs: [])?.frameCount, 1, "not counted unless a condition asks")
        let animated = Pipeline(steps: [PipelineStep(operation: .condition(ConditionalStep(
            conditions: [Condition(.isAnimated)], then: [.skip])))])
        XCTAssertEqual(animated.conditionFactNeeds, .frames)
        XCTAssertEqual(animated.resolved(forSource: gif).disposition, .skip)
    }

    func testNeedsFollowTheConditions() {
        func needs(_ conditions: [Condition]) -> FactNeeds {
            Pipeline(steps: [PipelineStep(operation: .condition(ConditionalStep(conditions: conditions)))]).conditionFactNeeds
        }
        XCTAssertEqual(needs([.width(.atLeast, 1), Condition(.name(TextMatch(.contains, "a")))]), [])
        XCTAssertEqual(needs([.hasTransparency(true)]), .alphaScan)
        XCTAssertEqual(needs([Condition(.date(.taken, .exists))]), .xmp)
        XCTAssertEqual(needs([Condition(.date(.created, .exists))]), [])
        XCTAssertEqual(needs([Condition(.metadata(MetadataTest(.named(.title), .exists)))]), .xmp)
        XCTAssertEqual(needs([Condition(.metadata(MetadataTest(.named(.iso), .exists)))]), [])
    }

    func testCacheRereadsWhenMoreIsNeeded() async throws {
        let gif = root.appendingPathComponent("anim.gif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil))
        for _ in 0..<2 { CGImageDestinationAddImage(dest, TestImages.make(width: 10, height: 10), nil) }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let cache = ItemFactsCache()
        let header = await cache.facts(for: gif, needs: [])
        XCTAssertEqual(header?.frameCount, 1)
        let counted = await cache.facts(for: gif, needs: .frames)
        XCTAssertEqual(counted?.frameCount, 2)
        _ = await cache.facts(for: gif, needs: [])
        let reads = await cache.readCount
        XCTAssertEqual(reads, 2, "a fuller entry answers a smaller need")
    }
}
