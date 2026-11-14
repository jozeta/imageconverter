import XCTest
import ImageIO
@testable import ImageconverterCore

final class MetadataEditorStateTests: XCTestCase {
    func testInvalidLocationDraftRemovesNeverKeeps() {
        var draft = LocationDraft()
        XCTAssertEqual(draft.edit, .remove)
        draft.latitude = "59,3293"
        XCTAssertEqual(draft.edit, .remove)
        draft.longitude = "18.0686"
        XCTAssertEqual(draft.edit, .set(latitude: 59.3293, longitude: 18.0686, altitude: nil))
        draft.altitude = "x"
        XCTAssertEqual(draft.edit, .remove)
        XCTAssertNotNil(draft.problem)
        draft.altitude = "28"
        XCTAssertEqual(draft.edit, .set(latitude: 59.3293, longitude: 18.0686, altitude: 28))
        draft.latitude = "91"
        XCTAssertEqual(draft.edit, .remove)
    }

    func testLocationDraftRoundTrip() {
        let location = LocationEdit.set(latitude: -12.5, longitude: 130.25, altitude: -3)
        XCTAssertEqual(LocationDraft(location).edit, location)
    }

    func testDateShiftRoundTripAndDirection() {
        let shift = DateShift(seconds: -(2 * 86_400 + 3 * 3_600 + 5 * 60))
        XCTAssertEqual(shift, DateShift(later: false, days: 2, hours: 3, minutes: 5))
        XCTAssertEqual(shift.seconds, -(2 * 86_400 + 3 * 3_600 + 5 * 60))
        XCTAssertFalse(DateShift(seconds: 0, laterWhenZero: false).later)
        XCTAssertEqual(DateShift(later: true, days: 999_999).seconds, DateEdit.maxShift)
    }

    func testEmptyCustomValueIsIgnored() {
        let input: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFSoftware as String: "Old"],
            kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCCity as String: "Town"],
        ]
        var options = MetadataOptions(isEnabled: true, removeLocation: false)
        options.custom = [MetadataField(namespace: .exif, key: "Software", value: ""),
                          MetadataField(namespace: .iptc, key: "City", value: "")]
        let out = MetadataOps.apply(options, to: input)
        let tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let iptc = out[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFSoftware as String] as? String, "Old")
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCity as String] as? String, "Town")
    }
}
