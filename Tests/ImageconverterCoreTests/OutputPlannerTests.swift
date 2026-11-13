import XCTest
@testable import ImageconverterCore

final class OutputPlannerTests: XCTestCase {
    private func item(_ name: String, dir: String = "", rel: String = "") -> InputItem {
        InputItem(source: URL(fileURLWithPath: "/src\(dir)/\(name)"), relativeDirectory: rel)
    }

    private let root = URL(fileURLWithPath: "/out")

    func testNewFolderIsFlat() {
        let plans = OutputPlanner.plan(
            [item("a.jpg", dir: "/Trip/day1", rel: "Trip/day1"), item("a.jpg", dir: "/Trip/day2", rel: "Trip/day2")],
            format: .jpeg, mode: .newFolder(root), fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/out/a.jpg", "/out/a_2.jpg"])
    }

    func testSameFolderNoSuffixWhenFormatChanges() {
        let plans = OutputPlanner.plan([item("IMG.heic")], format: .jpeg,
                                       mode: .sameFolder(suffix: "_new"), fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/IMG.jpg"])
    }

    func testSameFolderSuffixWhenNameEqualsOriginal() {
        let plans = OutputPlanner.plan([item("IMG.jpg"), item("img.JPG", dir: "/b")], format: .jpeg,
                                       mode: .sameFolder(suffix: "_new"), fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/IMG_new.jpg", "/src/b/img_new.jpg"])
    }

    func testSameFolderSuffixWhenRenamedToOriginalName() {
        let plans = OutputPlanner.plan([item("IMG.jpg")], format: .jpeg,
                                       mode: .sameFolder(suffix: "_new"), baseNames: ["IMG"],
                                       fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/IMG_new.jpg"])
    }

    func testSameFolderExistingFileGetsNumber() {
        let plans = OutputPlanner.plan([item("IMG.heic")], format: .jpeg,
                                       mode: .sameFolder(suffix: "_new"),
                                       fileExists: { $0.path == "/src/IMG.jpg" })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/IMG_2.jpg"])
    }

    func testOverwriteIgnoresBaseNames() {
        let plans = OutputPlanner.plan([item("a.jpg"), item("b.heic")], format: .jpeg, mode: .overwrite,
                                       baseNames: ["x", "y"], fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/a.jpg", "/src/b.jpg"])
        XCTAssertEqual(plans.map(\.replacesSource), [true, false])
    }

    func testSameFolderEmptySuffixNeverTargetsOriginal() {
        let plans = OutputPlanner.plan([item("IMG.jpg")], format: .jpeg,
                                       mode: .sameFolder(suffix: ""), fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/IMG_2.jpg"])
    }

    func testSameFolderSuffixWhenRenamedToOriginalNameDifferentCase() {
        let plans = OutputPlanner.plan([item("IMG.jpg")], format: .jpeg,
                                       mode: .sameFolder(suffix: "_new"), baseNames: ["img"],
                                       fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/img_new.jpg"])
        XCTAssertNotEqual(plans[0].destination.path.lowercased(), "/src/img.jpg")
    }

    func testDefaultSuffix() { XCTAssertEqual(OutputPlanner.defaultSuffix, "_new") }

    func testNewFolderIgnoresSubfolders() {
        let plans = OutputPlanner.plan(
            [item("b.jpg", dir: "/Trip/day2", rel: "Trip/day2"), item("c.heic")],
            format: .jpeg, mode: .newFolder(root), fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/out/b.jpg", "/out/c.jpg"])
        XCTAssertEqual(plans.map(\.replacesSource), [false, false])
        XCTAssertEqual(plans.map(\.trashesSource), [false, false])
    }

    func testSameFolderUsesSuffix() {
        let plans = OutputPlanner.plan([item("a.jpg")], format: .jpeg,
                                       mode: .sameFolder(suffix: "_converted"), fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/a_converted.jpg"])
        XCTAssertEqual(plans[0].replacesSource, false)
        XCTAssertEqual(plans[0].trashesSource, false)
    }

    func testOverwriteSameFormatReplacesInPlace() {
        let plans = OutputPlanner.plan([item("A.JPG")], format: .jpeg, mode: .overwrite,
                                       fileExists: { _ in true })
        XCTAssertEqual(plans[0].destination.path, "/src/A.JPG")
        XCTAssertEqual(plans[0].replacesSource, true)
        XCTAssertEqual(plans[0].trashesSource, false)
    }

    func testOverwriteFormatChangeTrashes() {
        let plans = OutputPlanner.plan([item("a.heic")], format: .jpeg, mode: .overwrite,
                                       fileExists: { _ in false })
        XCTAssertEqual(plans[0].destination.path, "/src/a.jpg")
        XCTAssertEqual(plans[0].replacesSource, false)
        XCTAssertEqual(plans[0].trashesSource, true)
    }

    func testSameNameInputsGetNumbered() {
        let plans = OutputPlanner.plan([item("IMG_1.HEIC"), item("IMG_1.png")], format: .jpeg,
                                       mode: .sameFolder(suffix: ""), fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.lastPathComponent), ["IMG_1.jpg", "IMG_1_2.jpg"])
        XCTAssertEqual(plans.map(\.replacesSource), [false, false])
        XCTAssertEqual(plans.map(\.trashesSource), [false, false])
    }

    func testNeverReplacesUnrelatedExistingFile() {
        let plans = OutputPlanner.plan([item("a.png")], format: .jpeg, mode: .overwrite,
                                       fileExists: { $0.path == "/src/a.jpg" })
        XCTAssertEqual(plans[0].destination.path, "/src/a_2.jpg")
        XCTAssertEqual(plans[0].replacesSource, false)
        XCTAssertEqual(plans[0].trashesSource, true)
    }

    func testSameFolderNeverTargetsOwnSource() {
        let plans = OutputPlanner.plan([item("a.jpg")], format: .jpeg,
                                       mode: .sameFolder(suffix: ""), fileExists: { $0.path == "/src/a.jpg" })
        XCTAssertEqual(plans[0].destination.path, "/src/a_2.jpg")
        XCTAssertEqual(plans[0].replacesSource, false)
        XCTAssertEqual(plans[0].trashesSource, false)
    }

    func testOverwriteWarningOnlyWhenSwitchingTo() {
        XCTAssertTrue(needsOverwriteWarning(from: .newFolder, to: .overwrite))
        XCTAssertTrue(needsOverwriteWarning(from: .sameFolder, to: .overwrite))
        XCTAssertFalse(needsOverwriteWarning(from: .overwrite, to: .overwrite))
        XCTAssertFalse(needsOverwriteWarning(from: .overwrite, to: .sameFolder))
        XCTAssertEqual(OutputMode.overwrite.kind, .overwrite)
        XCTAssertEqual(OutputMode.sameFolder(suffix: "x").kind, .sameFolder)
        XCTAssertEqual(OutputMode.newFolder(root).kind, .newFolder)
    }

    func testCollisionsAreCaseInsensitive() {
        let plans = OutputPlanner.plan([item("IMG_1.HEIC"), item("img_1.png")], format: .jpeg,
                                       mode: .sameFolder(suffix: ""), fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/IMG_1.jpg", "/src/img_1_2.jpg"])
        XCTAssertEqual(plans.map(\.replacesSource), [false, false])
        XCTAssertEqual(plans.map(\.trashesSource), [false, false])
    }

    func testOverwriteInPlaceTargetIsReservedFromOtherItems() {
        let plans = OutputPlanner.plan([item("a.png"), item("a.jpg")], format: .jpeg, mode: .overwrite,
                                       fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/a_2.jpg", "/src/a.jpg"])
        XCTAssertEqual(plans.map(\.replacesSource), [false, true])
        XCTAssertEqual(plans.map(\.trashesSource), [true, false])
    }

    func testThirdSameNameGetsNumberThree() {
        let plans = OutputPlanner.plan([item("a.heic"), item("a.png"), item("a.gif")], format: .jpeg,
                                       mode: .sameFolder(suffix: ""), fileExists: { _ in false })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/a.jpg", "/src/a_2.jpg", "/src/a_3.jpg"])
    }

    func testSuffixAndNumberingCombine() {
        let plans = OutputPlanner.plan([item("a.jpg")], format: .jpeg,
                                       mode: .sameFolder(suffix: "_converted"),
                                       fileExists: { $0.path == "/src/a_converted.jpg" })
        XCTAssertEqual(plans.map(\.destination.path), ["/src/a_converted_2.jpg"])
    }

    func testSuffixCannotEscapeSourceFolder() {
        let plans = OutputPlanner.plan([item("a.jpg")], format: .jpeg,
                                       mode: .sameFolder(suffix: "../x/:y"), fileExists: { _ in false })
        XCTAssertEqual(plans[0].destination.deletingLastPathComponent().path, "/src")
        XCTAssertEqual(plans[0].destination.path, "/src/a..xy.jpg")
    }
}
