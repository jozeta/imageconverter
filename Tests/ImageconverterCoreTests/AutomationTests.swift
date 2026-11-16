import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// The logic behind the Shortcuts actions (`Sources/Imageconverter/Intents/`), run without Shortcuts.
final class AutomationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func image(_ name: String, width: Int = 200, height: Int = 100, type: UTType = .jpeg,
                       properties: [String: Any] = [:]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: type, properties: properties)
        return url
    }

    private func outputFolder() throws -> URL {
        let url = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pixelSize(_ url: URL) throws -> (Int, Int) {
        let size = try XCTUnwrap(ImageLoader.pixelSize(of: url))
        return (size.width, size.height)
    }

    private let gps: [String: Any] = [kCGImagePropertyGPSDictionary as String: [
        kCGImagePropertyGPSLatitude as String: 59.3, kCGImagePropertyGPSLatitudeRef as String: "N",
        kCGImagePropertyGPSLongitude as String: 18.0, kCGImagePropertyGPSLongitudeRef as String: "E",
    ]]

    // MARK: Requests

    func testConvertUsesThePresetWithTheFormatOverride() throws {
        let preset = try ExternalRequests.preset(named: "web export", in: PresetStore.builtIns)
        let request = AutomationRequest.convert(preset: preset, format: .png)
        XCTAssertFalse(request.keepsSourceFormat)
        let pipeline = request.pipeline(sourceFormat: .jpeg)
        XCTAssertEqual(pipeline.output.format, .png)
        XCTAssertEqual(pipeline.steps.map(\.operation.kind), preset.pipeline.steps.map(\.operation.kind))
        XCTAssertEqual(pipeline.presetName, preset.name)
        XCTAssertEqual(AutomationRequest.convert(preset: preset, format: nil).pipeline(sourceFormat: .png).output.format,
                       preset.pipeline.output.format)
    }

    func testResizeAndStripKeepEachImagesFormat() throws {
        XCTAssertTrue(try AutomationRequest.resize(longEdge: 50).keepsSourceFormat)
        XCTAssertTrue(AutomationRequest.stripMetadata().keepsSourceFormat)
        XCTAssertEqual(AutomationRequest.stripMetadata().pipeline(sourceFormat: .heic).output.format, .heic)
        XCTAssertTrue(AutomationRequest.stripMetadata().pipeline(sourceFormat: .png).metadata.removeAll)
    }

    func testInvalidValuesAreRefused() {
        XCTAssertThrowsError(try AutomationRequest.resize(longEdge: 0)) {
            XCTAssertEqual($0 as? AutomationError, .invalidLongEdge(0))
        }
        XCTAssertThrowsError(try AutomationRequest.resize(longEdge: Automation.maxLongEdge + 1))
        XCTAssertThrowsError(try AutomationRequest.convertFormat(.jpeg, qualityPercent: 0)) {
            XCTAssertEqual($0 as? AutomationError, .invalidQuality(0))
        }
        XCTAssertThrowsError(try AutomationRequest.convertFormat(.jpeg, qualityPercent: 101))
        XCTAssertEqual(try AutomationRequest.convertFormat(.heic, qualityPercent: 60).pipeline(sourceFormat: .png)
            .output.quality, 0.6)
    }

    func testSourceFormatFallsBackToJPEGOrPNG() throws {
        let png = try image("a.png", type: .png)
        let jpeg = try image("b.jpg")
        XCTAssertEqual(Automation.sourceFormat(of: png, writable: OutputFormat.allCases), .png)
        XCTAssertEqual(Automation.sourceFormat(of: jpeg, writable: OutputFormat.allCases), .jpeg)
        // A format this Mac can't write: PNG for a format with transparency, JPEG otherwise.
        XCTAssertEqual(Automation.sourceFormat(of: png, writable: [.jpeg]), .jpeg)
        XCTAssertEqual(Automation.sourceFormat(of: png, writable: [.jpeg, .png, .tiff].filter { $0 != .png }), .jpeg)
        XCTAssertEqual(Automation.sourceFormat(of: dir.appendingPathComponent("missing.jpg"),
                                               writable: OutputFormat.allCases), .jpeg)
    }

    // MARK: Running

    func testResizeWritesSmallerCopiesAndLeavesOriginals() async throws {
        let jpeg = try image("photo.jpg")
        let png = try image("shot.png", width: 80, height: 160, type: .png)
        let before = try Data(contentsOf: jpeg)
        let out = try outputFolder()
        let result = try await Automation.run([jpeg, png], request: .resize(longEdge: 40), output: out)
        XCTAssertEqual(result.written.map(\.lastPathComponent).sorted(), ["photo.jpg", "shot.png"])
        let sizes = try result.written.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(pixelSize)
        XCTAssertEqual(sizes.map(\.0), [40, 20])
        XCTAssertEqual(sizes.map(\.1), [20, 40])
        XCTAssertEqual(try Data(contentsOf: jpeg), before, "the original is never changed")
        XCTAssertTrue(result.written.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL })
    }

    func testStripMetadataRemovesGPS() async throws {
        let jpeg = try image("gps.jpg", properties: gps)
        XCTAssertNotNil(try TestImages.properties(of: Data(contentsOf: jpeg))[kCGImagePropertyGPSDictionary as String])
        let result = try await Automation.run([jpeg], request: .stripMetadata(), output: try outputFolder())
        let written = try XCTUnwrap(result.written.first)
        XCTAssertEqual(written.pathExtension, "jpg")
        XCTAssertNil(try TestImages.properties(of: Data(contentsOf: written))[kCGImagePropertyGPSDictionary as String])
    }

    func testConvertFormatAndNamesNeverReplaceExistingFiles() async throws {
        let jpeg = try image("photo.jpg")
        let out = try outputFolder()
        let request = try AutomationRequest.convertFormat(.png, qualityPercent: nil)
        let first = try await Automation.run([jpeg], request: request, output: out)
        let second = try await Automation.run([jpeg], request: request, output: out)
        XCTAssertEqual(first.written.map(\.lastPathComponent), ["photo.png"])
        XCTAssertEqual(second.written.map(\.lastPathComponent), ["photo_2.png"])
        XCTAssertEqual(CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(first.written[0] as CFURL, nil)))
            as String?, UTType.png.identifier)
    }

    func testFoldersAreExpanded() async throws {
        let folder = dir.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestImages.write(TestImages.make(width: 10, height: 10), to: folder.appendingPathComponent("a.jpg"), type: .jpeg)
        try TestImages.write(TestImages.make(width: 10, height: 10), to: folder.appendingPathComponent("b.jpg"), type: .jpeg)
        let preset = try ExternalRequests.preset(named: "Web export", in: PresetStore.builtIns)
        let result = try await Automation.run([folder], request: .convert(preset: preset, format: nil),
                                              output: try outputFolder())
        XCTAssertEqual(result.written.count, 2)
    }

    func testEmptyInputAndNoImagesAreErrors() async throws {
        let out = try outputFolder()
        do {
            _ = try await Automation.run([], request: .stripMetadata(), output: out)
            XCTFail("no files must fail")
        } catch { XCTAssertEqual(error as? AutomationError, .noFiles) }
        let text = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        do {
            _ = try await Automation.run([text], request: .stripMetadata(), output: out)
            XCTFail("a text file must fail")
        } catch { XCTAssertEqual(error as? AutomationError, .noImages) }
    }

    func testEveryFileFailingIsAnErrorWithTheReason() async throws {
        let broken = dir.appendingPathComponent("broken.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0x00, 0x01]).write(to: broken)
        do {
            _ = try await Automation.run([broken], request: .stripMetadata(), output: try outputFolder())
            XCTFail("a broken file must fail")
        } catch let error as AutomationError {
            guard case .nothingWritten(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(reason.contains("broken.jpg"), reason)
            XCTAssertTrue(error.message.hasPrefix("No image was converted"), error.message)
        }
    }

    func testUnwritableFormatIsRefusedBeforeRunning() async throws {
        let jpeg = try image("photo.jpg")
        do {
            _ = try await Automation.run([jpeg], request: try .convertFormat(.avif, qualityPercent: 50),
                                         output: try outputFolder(), writable: [.jpeg, .png])
            XCTFail("AVIF must be refused")
        } catch { XCTAssertEqual(error as? AutomationError, .formatNotWritable("AVIF")) }
    }

    // MARK: Folders and scratch space

    func testFolderChecksPointToFolderAccess() throws {
        let out = try outputFolder()
        XCTAssertEqual(try Automation.checkedFolder(out, isUsable: { _ in true }), out.standardizedFileURL)
        XCTAssertThrowsError(try Automation.checkedFolder(out, isUsable: { _ in false })) { error in
            XCTAssertEqual(error as? AutomationError, .folderNotAllowed(path: out.standardizedFileURL.path))
            XCTAssertTrue((error as? AutomationError)?.message.contains("Help \u{25B8} Folder Access") == true)
        }
        XCTAssertThrowsError(try Automation.checkedFolder(URL(fileURLWithPath: "/nope/missing"), isUsable: { _ in true }))
    }

    func testScratchFoldersAreFreshAndOldOnesRemoved() throws {
        let base = dir.appendingPathComponent("scratch", isDirectory: true)
        let old = try Automation.newScratchFolder(in: base, now: Date(timeIntervalSinceNow: -3 * 86_400))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)],
                                              ofItemAtPath: old.path)
        let new = try Automation.newScratchFolder(in: base)
        XCTAssertNotEqual(old, new)
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "folders over a day old are removed")
    }

    // MARK: Metadata text

    func testMetadataTextListsGroupsAndValues() throws {
        let jpeg = try image("gps.jpg", properties: gps)
        let text = try Automation.metadataText(of: jpeg)
        XCTAssertTrue(text.hasPrefix("gps.jpg\n"), text)
        XCTAssertTrue(text.contains("\nFile\n"), text)
        XCTAssertTrue(text.contains("\nLocation (GPS)\n"), text)
        XCTAssertTrue(text.contains("  "), text)
        XCTAssertThrowsError(try Automation.metadataText(of: dir.appendingPathComponent("missing.jpg")))
    }

    func testMessagesForEveryError() {
        let errors: [Error] = [AutomationError.noFiles, AutomationError.noImages, AutomationError.cancelled,
                               ExternalRequestError.unknownPreset(name: "X"), CocoaError(.fileNoSuchFile)]
        for error in errors { XCTAssertFalse(Automation.message(for: error).isEmpty) }
        XCTAssertEqual(Automation.message(for: ExternalRequestError.unknownPreset(name: "X")),
                       "There is no preset named \"X\".")
    }
}
