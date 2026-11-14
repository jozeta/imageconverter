import XCTest
@testable import ImageconverterCore

final class SizePresetsTests: XCTestCase {
    func testPresetsValid() {
        let all = SizePresets.all
        XCTAssertEqual(SizePresets.social.count, 22)
        XCTAssertEqual(SizePresets.resolutions.count, 5)
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "names are unique")
        let groups = [SizePresets.printPhotoCentimetres, SizePresets.printPhotoInches, SizePresets.printPaper,
                      SizePresets.web, SizePresets.devices, SizePresets.assets, SizePresets.social,
                      SizePresets.resolutions]
        XCTAssertEqual(groups.map(\.count), [9, 5, 8, 7, 11, 7, 22, 5])
        XCTAssertEqual(groups.flatMap { $0 }.count, all.count)
        for preset in all {
            XCTAssertFalse(preset.sizeLabel.isEmpty, preset.name)
            XCTAssertFalse(preset.menuTitle.isEmpty, preset.name)
            XCTAssertGreaterThan(preset.width, 0, preset.name)
            XCTAssertGreaterThan(preset.height, 0, preset.name)
        }
        for ratio in SizePresets.aspectRatios {
            XCTAssertGreaterThan(ratio.width, 0)
            XCTAssertGreaterThan(ratio.height, 0)
        }
        XCTAssertEqual(SizePresets.aspectRatios.map(\.name),
                       ["1:1", "4:5", "4:3", "3:2", "5:4", "16:9", "9:16", "21:9", "2:3", "3:4"])
    }

    func testPresetModes() throws {
        let square = try XCTUnwrap(SizePresets.social.first { $0.name == "Instagram square" })
        XCTAssertEqual(square.mode, .exactSize(width: 1080, height: 1080, fill: .fillAndCrop))
        let fourK = try XCTUnwrap(SizePresets.resolutions.first { $0.name == "4K" })
        XCTAssertEqual(fourK.mode, .fitBox(width: 3840, height: 2160))
        XCTAssertFalse(fourK.allowEnlarge)
    }

    func testApplyingAPresetKeepsResamplingAndDPI() throws {
        let story = try XCTUnwrap(SizePresets.social.first { $0.width == 1080 && $0.height == 1920 })
        let options = story.applied(to: ResizeOptions(mode: .percent(50), resampling: .bicubic, dpi: 72))
        XCTAssertEqual(options.mode, .exactSize(width: 1080, height: 1920, fill: .fillAndCrop))
        XCTAssertEqual(options.resampling, .bicubic)
        XCTAssertEqual(options.dpi, 72)
        XCTAssertEqual(SizePresets.aspectRatios[5].cropMode, .aspect(width: 16, height: 9))
    }

    func testKindsSetTheExpectedMode() throws {
        let base = ResizeOptions(mode: .percent(50), allowEnlarge: false, resampling: .bicubic, dpi: 72)
        let web = try XCTUnwrap(SizePresets.web.first { $0.name == "Large" })
        XCTAssertEqual(web.applied(to: base).mode, .longestEdge(1920))
        XCTAssertFalse(web.applied(to: base).allowEnlarge)
        let device = try XCTUnwrap(SizePresets.devices.first { $0.name == "4K UHD" })
        XCTAssertEqual(device.applied(to: base).mode, .exactSize(width: 3840, height: 2160, fill: .fillAndCrop))
        XCTAssertTrue(device.applied(to: base).allowEnlarge)
        let photo = try XCTUnwrap(SizePresets.printPhotoCentimetres.first { $0.name == "10 × 15 cm" })
        let printed = photo.applied(to: base)
        XCTAssertEqual(printed.mode, .printSheet(long: 15, short: 10, unit: .centimetre, dpi: 300))
        XCTAssertEqual(printed.effectiveDPI, 300)
        XCTAssertEqual(printed.resampling, .bicubic)
        XCTAssertEqual(photo.menuTitle, "10 × 15 cm")
        let paperA4 = try XCTUnwrap(SizePresets.printPaper.first { $0.name == "A4" })
        XCTAssertEqual(paperA4.menuTitle, "A4 (21 × 29.7 cm)")
        XCTAssertEqual(paperA4.mode, .printSheet(long: 29.7, short: 21, unit: .centimetre, dpi: 300))
        let letter = try XCTUnwrap(SizePresets.printPaper.first { $0.name == "Letter" })
        XCTAssertEqual(letter.sizeLabel, "8.5 × 11 in")
        XCTAssertEqual(SizePresets.social.first { $0.name == "Threads" }?.sizeLabel, "1080 × 1350")
    }

    func testPrintSheetFollowsOrientation() {
        let options = ResizeOptions(mode: .printSheet(long: 15, short: 10, unit: .centimetre, dpi: 300))
        // 15 cm = 1772 px, 10 cm = 1181 px at 300 dpi.
        XCTAssertEqual(Geometry.resizePlan(source: CGSize(width: 6000, height: 4000), options: options),
                       .scale(to: CGSize(width: 1772, height: 1181)))
        XCTAssertEqual(Geometry.resizePlan(source: CGSize(width: 4000, height: 6000), options: options),
                       .scale(to: CGSize(width: 1181, height: 1772)))
        // A fitting aspect ratio other than 3:2 fits inside; small images are enlarged.
        XCTAssertEqual(Geometry.resizePlan(source: CGSize(width: 800, height: 800), options: options),
                       .scale(to: CGSize(width: 1181, height: 1181)))
    }

    func testPrintSheetCodableAndDPI() throws {
        let options = ResizeOptions(mode: .printSheet(long: 15, short: 10, unit: .centimetre, dpi: 300), dpi: 72)
        let decoded = try JSONDecoder().decode(ResizeOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
        XCTAssertEqual(options.effectiveDPI, 300)
        // Saved options from before the presets still decode.
        let old = #"{"mode":{"fitBox":{"width":1920,"height":1080}},"allowEnlarge":false}"#
        XCTAssertEqual(try JSONDecoder().decode(ResizeOptions.self, from: Data(old.utf8)).mode,
                       .fitBox(width: 1920, height: 1080))
    }
}
