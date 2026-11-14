import XCTest
@testable import ImageconverterCore

final class ExternalRequestsTests: XCTestCase {
    private let readable: Set<String> = ["/in/a.jpg", "/in/b.png"]
    private let folders: Set<String> = ["/out"]
    private var mine: Preset { Preset(name: "Mine", pipeline: Pipeline(output: OutputSettings(format: .png))) }

    private func plan(_ files: [String], preset: String = "web EXPORT", folder: String? = nil,
                      global: OutputMode? = .sameFolder(suffix: "_c")) throws -> ConvertPlan {
        try ExternalRequests.convertPlan(
            files: files.map { URL(fileURLWithPath: $0) }, presetName: preset,
            folder: folder.map { URL(fileURLWithPath: $0, isDirectory: true) },
            presets: PresetStore.builtIns + [mine], globalMode: global,
            isReadable: { self.readable.contains($0.path) }, isDirectory: { self.folders.contains($0.path) })
    }

    func testConvertWithGlobalMode() throws {
        let result = try plan(["/in/a.jpg", "/in/b.png", "/in/./a.jpg"])
        XCTAssertEqual(result.files.map(\.path), ["/in/a.jpg", "/in/b.png"])
        XCTAssertEqual(result.preset.name, "Web export")
        XCTAssertEqual(result.mode, .sameFolder(suffix: "_c"))
        XCTAssertFalse(result.needsOverwriteConfirmation)
    }

    func testConvertToFolderUsesANewFolderOutput() throws {
        let result = try plan(["/in/a.jpg"], preset: " mine ", folder: "/out", global: .overwrite)
        XCTAssertEqual(result.mode, .newFolder(URL(fileURLWithPath: "/out", isDirectory: true).standardizedFileURL))
        XCTAssertEqual(result.preset.name, "Mine")
        XCTAssertFalse(result.needsOverwriteConfirmation)
    }

    func testOverwriteModeAlwaysNeedsConfirmation() throws {
        XCTAssertTrue(try plan(["/in/a.jpg"], global: .overwrite).needsOverwriteConfirmation)
    }

    func testConvertErrors() {
        XCTAssertThrowsError(try plan([])) { XCTAssertEqual($0 as? ExternalRequestError, .noFiles) }
        XCTAssertThrowsError(try plan(["/in/a.jpg", "/in/gone.jpg"])) {
            XCTAssertEqual($0 as? ExternalRequestError, .unreadable(path: "/in/gone.jpg"))
        }
        XCTAssertThrowsError(try plan(["/in/a.jpg"], preset: "Nope")) {
            XCTAssertEqual($0 as? ExternalRequestError, .unknownPreset(name: "Nope"))
        }
        XCTAssertThrowsError(try plan(["/in/a.jpg"], folder: "/elsewhere")) {
            XCTAssertEqual($0 as? ExternalRequestError, .notAFolder(path: "/elsewhere"))
        }
        XCTAssertThrowsError(try plan(["/in/a.jpg"], global: nil)) {
            XCTAssertEqual($0 as? ExternalRequestError, .noOutputFolder)
        }
    }

    func testNonFileURLsAreRejected() throws {
        let web = try XCTUnwrap(URL(string: "https://example.com/a.jpg"))
        XCTAssertThrowsError(try ExternalRequests.validatedFiles([web]) { _ in true })
        XCTAssertThrowsError(try ExternalRequests.validatedFolder(web) { _ in true })
    }

    func testTooManyFiles() {
        let urls = Array(repeating: URL(fileURLWithPath: "/in/a.jpg"), count: ExternalRequests.maxFiles + 1)
        XCTAssertThrowsError(try ExternalRequests.validatedFiles(urls) { _ in true }) {
            XCTAssertEqual($0 as? ExternalRequestError, .tooManyFiles(max: ExternalRequests.maxFiles))
        }
    }

    func testJobByName() throws {
        let jobs = [Job(name: "Nightly", inputs: [], output: .overwrite)]
        XCTAssertEqual(try ExternalRequests.job(named: "NIGHTLY", in: jobs).name, "Nightly")
        XCTAssertThrowsError(try ExternalRequests.job(named: "Daily", in: jobs))
        XCTAssertThrowsError(try ExternalRequests.job(named: "", in: jobs))
    }

    func testErrorMessagesAreReadable() {
        XCTAssertTrue(ExternalRequestError.unknownPreset(name: "X").message.contains("\"X\""))
        XCTAssertFalse(ExternalRequestError.busy.message.isEmpty)
    }

    func testScriptValues() throws {
        let file = URL(fileURLWithPath: "/in/a.jpg")
        XCTAssertEqual(try ExternalRequests.fileURLs(fromScriptValue: file), [file])
        XCTAssertEqual(try ExternalRequests.fileURLs(fromScriptValue: [file, file] as [Any]), [file, file])
        XCTAssertEqual(try ExternalRequests.fileURLs(fromScriptValue: [] as [Any]), [])
        // Full POSIX paths as text work too, alone or mixed with files.
        XCTAssertEqual(try ExternalRequests.fileURLs(fromScriptValue: "/in/a.jpg"), [file])
        XCTAssertEqual(try ExternalRequests.fileURLs(fromScriptValue: [file, "/in/b.png"] as [Any]),
                       [file, URL(fileURLWithPath: "/in/b.png")])
        XCTAssertThrowsError(try ExternalRequests.fileURLs(fromScriptValue: "a.jpg")) {
            XCTAssertEqual($0 as? ExternalRequestError, .notAFile(description: "a.jpg"))
        }
        XCTAssertThrowsError(try ExternalRequests.fileURLs(fromScriptValue: 42)) {
            XCTAssertTrue(($0 as? ExternalRequestError)?.message.contains("POSIX") == true)
        }
        XCTAssertThrowsError(try ExternalRequests.fileURLs(fromScriptValue: nil)) {
            XCTAssertEqual($0 as? ExternalRequestError, .noFiles)
        }
    }

    func testMissingPathStringsGiveAClearError() throws {
        let urls = try ExternalRequests.fileURLs(fromScriptValue: "/in/gone.jpg")
        XCTAssertThrowsError(try ExternalRequests.validatedFiles(urls) { _ in false }) {
            XCTAssertEqual(($0 as? ExternalRequestError)?.message, "/in/gone.jpg doesn't exist or can't be read.")
        }
    }

    func testFileListShowsFiveThenACount() {
        let urls = (1...7).map { URL(fileURLWithPath: "/in/\($0).jpg") }
        XCTAssertEqual(ExternalRequests.fileList(Array(urls.prefix(2))), "/in/1.jpg\n/in/2.jpg")
        let list = ExternalRequests.fileList(urls)
        XCTAssertEqual(list.components(separatedBy: "\n").count, 6)
        XCTAssertTrue(list.hasSuffix("/in/5.jpg\n…and 2 more"))
    }

    func testRunSummaryNamesPresetModeAndFiles() {
        let text = ExternalRequests.runSummary(files: [URL(fileURLWithPath: "/in/a.jpg")],
                                               pipelineName: "the preset Web export", mode: .overwrite)
        XCTAssertTrue(text.hasPrefix("Converts 1 image with the preset Web export and replaces the original"))
        XCTAssertTrue(text.hasSuffix("\n\n/in/a.jpg"))
    }

    func testModeDescriptions() {
        XCTAssertTrue(ExternalRequests.describe(.overwrite).contains("replaces the original"))
        XCTAssertTrue(ExternalRequests.describe(.newFolder(URL(fileURLWithPath: "/out"))).contains("/out"))
        XCTAssertTrue(ExternalRequests.describe(.sameFolder(suffix: "_c")).contains("\"_c\""))
    }

    // MARK: Service pins

    private func preset(_ name: String, slot: Int? = nil) -> Preset {
        Preset(name: name, pipeline: Pipeline(), serviceSlot: slot)
    }

    func testSlotsAreExplicit() {
        let list = [preset("z", slot: 1), preset("a", slot: 3), preset("m"), preset("b", slot: 2)]
        XCTAssertEqual(ServicePins.pinned(list).map(\.name), ["z", "b", "a"])
        XCTAssertEqual(ServicePins.preset(forSlot: 1, in: list)?.name, "z")
        XCTAssertEqual(ServicePins.preset(forSlot: 3, in: list)?.name, "a")
        XCTAssertNil(ServicePins.preset(forSlot: 4, in: list))
        XCTAssertNil(ServicePins.preset(forSlot: 0, in: list))
        XCTAssertEqual(ServicePins.freeSlot(in: list), 4)
    }

    func testAFreedSlotIsReusedFirst() {
        let list = [preset("a", slot: 1), preset("c", slot: 3)]
        XCTAssertEqual(ServicePins.freeSlot(in: list), 2)
    }

    func testDuplicateSlotsPickTheFirstByName() {
        let list = [preset("b", slot: 2), preset("A", slot: 2)]
        XCTAssertEqual(ServicePins.preset(forSlot: 2, in: list)?.name, "A")
        XCTAssertEqual(ServicePins.pinned(list).count, 1)
    }

    func testBuiltInsAreNeverPinned() {
        var builtIn = PresetStore.builtIns[0]
        builtIn.serviceSlot = 1
        XCTAssertTrue(ServicePins.pinned([builtIn]).isEmpty)
        XCTAssertEqual(ServicePins.freeSlot(in: [builtIn]), 1)
    }

    func testCanPinWhileASlotIsFree() {
        let full = (1...5).map { preset("p\($0)", slot: $0) } + [preset("free")]
        XCTAssertNil(ServicePins.freeSlot(in: full))
        XCTAssertFalse(ServicePins.canPin(full[5].id, in: full))
        // A pinned preset can always be pinned again (and unpinned).
        XCTAssertTrue(ServicePins.canPin(full[0].id, in: full))
    }
}
