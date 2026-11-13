import XCTest
@testable import ImageconverterCore

final class PresetSessionTests: XCTestCase {
    private var web: Preset { PresetStore.builtIns[0] }
    private var archive: Preset { PresetStore.builtIns[2] }
    private let user = Preset(name: "Mine", pipeline: Pipeline(output: OutputSettings(format: .png)))

    private func edited(_ session: PresetSession) -> PresetSession {
        var copy = session
        copy.pipeline.output.format = .heic
        return copy
    }

    func testSelectWithoutEditsIsDone() {
        var session = PresetSession()
        XCTAssertEqual(session.select(web), .done)
        XCTAssertEqual(session.selected, web)
        XCTAssertEqual(session.pipeline, web.pipeline)
        XCTAssertFalse(session.isModified)
    }

    func testSelectAfterEditNeedsConfirmationThenForceReplaces() {
        var session = PresetSession()
        _ = session.select(web)
        session = edited(session)
        XCTAssertTrue(session.isModified)
        XCTAssertEqual(session.select(archive), .needsConfirmation)
        XCTAssertEqual(session.selected, web)
        XCTAssertEqual(session.select(archive, force: true), .done)
        XCTAssertEqual(session.selected, archive)
        XCTAssertEqual(session.pipeline, archive.pipeline)
        XCTAssertFalse(session.isModified)
    }

    func testResetRestoresPipeline() {
        var session = PresetSession()
        _ = session.select(web)
        session = edited(session)
        session.resetToPreset()
        XCTAssertEqual(session.pipeline, web.pipeline)
        XCTAssertFalse(session.isModified)
    }

    func testSaveTarget() {
        var session = PresetSession()
        XCTAssertEqual(session.saveTarget(), .saveAs)
        _ = session.select(web)
        XCTAssertEqual(session.saveTarget(), .saveAs)
        _ = session.select(user)
        XCTAssertEqual(session.saveTarget(), .overwrite(user.id))
    }

    func testDidSaveClearsModified() {
        var session = PresetSession()
        _ = session.select(user)
        session = edited(session)
        XCTAssertTrue(session.isModified)
        var saved = user
        saved.pipeline = session.pipeline
        session.didSave(saved)
        XCTAssertFalse(session.isModified)
        XCTAssertEqual(session.selected, saved)
    }

    func testAdHocIsNeverModified() {
        var session = PresetSession()
        session.pipeline.output.format = .heic
        XCTAssertFalse(session.isModified)
        _ = session.select(web)
        session.deselect()
        XCTAssertNil(session.selected)
        XCTAssertFalse(session.isModified)
    }

    func testRestoredSessionIsModified() {
        var pipeline = web.pipeline
        pipeline.output.format = .heic
        let session = PresetSession(selected: web, pipeline: pipeline)
        XCTAssertTrue(session.isModified)
    }
}
