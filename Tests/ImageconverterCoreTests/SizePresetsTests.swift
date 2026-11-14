import XCTest
@testable import ImageconverterCore

final class SizePresetsTests: XCTestCase {
    func testPresetsValid() {
        let all = SizePresets.social + SizePresets.resolutions
        XCTAssertEqual(SizePresets.social.count, 12)
        XCTAssertEqual(SizePresets.resolutions.count, 5)
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "names are unique")
        for preset in all {
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
}
