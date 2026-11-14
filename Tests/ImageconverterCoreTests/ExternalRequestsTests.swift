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

    func testScriptValues() {
        let file = URL(fileURLWithPath: "/in/a.jpg")
        XCTAssertEqual(ExternalRequests.fileURLs(fromScriptValue: file), [file])
        XCTAssertEqual(ExternalRequests.fileURLs(fromScriptValue: [file, file] as [Any]), [file, file])
        XCTAssertEqual(ExternalRequests.fileURLs(fromScriptValue: [] as [Any]), [])
        XCTAssertNil(ExternalRequests.fileURLs(fromScriptValue: "/in/a.jpg"))
        XCTAssertNil(ExternalRequests.fileURLs(fromScriptValue: [file, "/in/b.png"] as [Any]))
        XCTAssertNil(ExternalRequests.fileURLs(fromScriptValue: nil))
    }

    func testModeDescriptions() {
        XCTAssertTrue(ExternalRequests.describe(.overwrite).contains("replaces the original"))
        XCTAssertTrue(ExternalRequests.describe(.newFolder(URL(fileURLWithPath: "/out"))).contains("/out"))
        XCTAssertTrue(ExternalRequests.describe(.sameFolder(suffix: "_c")).contains("\"_c\""))
    }

    // MARK: Service pins

    private func presets(pinned: [String], unpinned: [String] = []) -> [Preset] {
        pinned.map { Preset(name: $0, pipeline: Pipeline(), pinnedForServices: true) }
            + unpinned.map { Preset(name: $0, pipeline: Pipeline()) }
    }

    func testPinnedAreSortedAndCapped() {
        let list = presets(pinned: ["f", "B", "a", "e", "d", "c"], unpinned: ["0"])
        XCTAssertEqual(ServicePins.pinned(list).map(\.name), ["a", "B", "c", "d", "e"])
        XCTAssertEqual(ServicePins.preset(forSlot: 1, in: list)?.name, "a")
        XCTAssertEqual(ServicePins.preset(forSlot: 5, in: list)?.name, "e")
        XCTAssertNil(ServicePins.preset(forSlot: 6, in: list))
        XCTAssertNil(ServicePins.preset(forSlot: 0, in: list))
    }

    func testBuiltInsAreNeverPinned() {
        var builtIn = PresetStore.builtIns[0]
        builtIn.pinnedForServices = true
        XCTAssertTrue(ServicePins.pinned([builtIn]).isEmpty)
    }

    func testCanPinUpToFive() {
        let four = presets(pinned: ["a", "b", "c", "d"], unpinned: ["e"])
        XCTAssertTrue(ServicePins.canPin(four[4].id, in: four))
        let five = presets(pinned: ["a", "b", "c", "d", "e"], unpinned: ["f"])
        XCTAssertFalse(ServicePins.canPin(five[5].id, in: five))
        // A pinned preset can always be pinned again (and unpinned).
        XCTAssertTrue(ServicePins.canPin(five[0].id, in: five))
    }
}
