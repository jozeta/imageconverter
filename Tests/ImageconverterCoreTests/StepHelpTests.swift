import XCTest
@testable import ImageconverterCore

final class StepHelpTests: XCTestCase {
    func testEveryTopicHasHelp() {
        for topic in StepHelpTopic.all {
            let info = StepHelp.info(for: topic)
            XCTAssertFalse(info.title.isEmpty, "\(topic)")
            XCTAssertFalse(info.summary.isEmpty, "\(topic)")
            XCTAssertFalse(info.howTo.isEmpty, "\(topic)")
            XCTAssertLessThanOrEqual(info.howTo.count, 5, "\(topic)")
            XCTAssertLessThanOrEqual(info.tips.count, 3, "\(topic)")
        }
    }

    func testBulletsAreShort() {
        for topic in StepHelpTopic.all {
            let info = StepHelp.info(for: topic)
            for line in info.howTo + info.tips {
                XCTAssertLessThanOrEqual(line.count, 160, "\(topic): \(line)")
            }
        }
    }

    func testTopicsCoverEveryStepKind() {
        XCTAssertEqual(StepHelpTopic.all.count, StepKind.allCases.count + 3)
        XCTAssertEqual(StepHelp.info(for: .resize).title, "Resize")
    }

    func testResizeHelpExplainsMLEnlarge() {
        XCTAssertTrue(StepHelp.info(for: .resize).howTo.contains { $0.contains("Enlarge with machine learning") })
    }
}
