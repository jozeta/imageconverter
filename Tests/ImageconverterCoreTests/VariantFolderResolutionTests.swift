import XCTest
@testable import ImageconverterCore

/// Fix round 1 of the extra outputs' own folders: one resolution for the access check, the plan and the write; a
/// bookmark is followed only when it is this app's (security-scoped) or names the stored folder.
final class VariantFolderResolutionTests: XCTestCase {
    private var root: URL!
    private var out: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
        out = root.appendingPathComponent("out", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, in folder: URL? = nil) throws -> URL {
        let directory = folder ?? root!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try TestImages.write(TestImages.noise(width: 300, height: 200), to: url, type: .jpeg)
        return url
    }

    private func items(_ urls: [URL]) -> [InputItem] { urls.map { InputItem(source: $0, relativeDirectory: "") } }

    private func relative(_ url: URL) -> String { url.path.replacingOccurrences(of: root.path + "/", with: "") }

    private func scopedBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func plainBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func testAMovedFolderIsFollowedForAccessPlanAndWrite() async throws {
        let photo = try source("a.jpg", in: root.appendingPathComponent("src"))
        let old = root.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let folder = VariantFolder(path: old.path, bookmark: try scopedBookmark(old))
        let moved = root.appendingPathComponent("Site", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: moved)
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), extraOutputs: [
            OutputVariant(name: "Web", nameSuffix: "_web", destination: .folder(folder)),
        ])
        // Resolved once: the pipeline now names the new place (with a renewed bookmark when stale).
        let check = pipeline.checkingVariantFolders()
        XCTAssertTrue(check.changed)
        XCTAssertTrue(check.unconfirmed.isEmpty)
        XCTAssertEqual(check.pipeline.extraOutputs[0].chosenFolder?.path, moved.standardizedFileURL.path)
        // Access is asked for the new location, not the old path.
        let needs = AccessNeeds.needs(sources: [photo], mode: .newFolder(out), extraOutputs: check.pipeline.extraOutputs,
                                      covered: [out])
        XCTAssertEqual(needs.map { $0.folder.resolvingSymlinksInPath().path }, [moved.resolvingSymlinksInPath().path])
        // The files land there, whichever of the two pipelines runs.
        for run in [check.pipeline, pipeline] {
            let report = await BatchRunner.run(items([photo]), pipeline: run, mode: .newFolder(out),
                                               variantFolders: .confirmedOnly)
            XCTAssertEqual(report.failures, [])
            XCTAssertEqual(report.written.dropFirst().map { $0.deletingLastPathComponent().lastPathComponent },
                           ["Site"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testAForeignPlainBookmarkIsNeverFollowed() async throws {
        let photo = try source("a.jpg", in: root.appendingPathComponent("src"))
        let stored = root.appendingPathComponent("X", isDirectory: true)
        let elsewhere = root.appendingPathComponent("Y", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let folder = VariantFolder(path: stored.path, bookmark: try plainBookmark(elsewhere))
        XCTAssertEqual(folder.resolution(sandboxEnforced: false), .unconfirmed(folder.url))
        XCTAssertEqual(folder.resolution(sandboxEnforced: true), .unconfirmed(folder.url))
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), extraOutputs: [
            OutputVariant(name: "Web", nameSuffix: "_web", destination: .folder(folder)),
        ])
        let check = pipeline.checkingVariantFolders()
        XCTAssertFalse(check.changed)
        XCTAssertEqual(check.unconfirmed.map(\.name), ["Web"])
        // The command line writes to the stored path X; the app and jobs refuse with a note. Never Y.
        let trusted = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out),
                                            variantFolders: .trustPaths)
        XCTAssertEqual(trusted.written.map(relative), ["out/a.jpg", "X/a_web.jpg"])
        try FileManager.default.removeItem(at: out)
        let refused = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out),
                                            variantFolders: .confirmedOnly)
        XCTAssertEqual(refused.written.map(relative), ["out/a.jpg"])
        XCTAssertTrue(refused.entries.contains { ($0.note ?? "").contains("choose the folder again") },
                      "\(refused.entries.map(\.note))")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testAFolderJustChosenWithoutABookmarkIsWritten() async throws {
        // The user chose the folder in this run's open panel, but no bookmark could be made: the run still
        // writes there (the panel gave access), other unconfirmed folders are still refused.
        let photo = try source("a.jpg", in: root.appendingPathComponent("src"))
        let chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        for folder in [chosen, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), extraOutputs: [
            OutputVariant(name: "Web", nameSuffix: "_web", destination: .folder(VariantFolder(path: chosen.path))),
            OutputVariant(name: "Print", nameSuffix: "_print", destination: .folder(VariantFolder(path: other.path))),
        ])
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out),
                                           variantFolders: .confirmedOr(chosen: [chosen.path]))
        XCTAssertEqual(report.written.map(relative), ["out/a.jpg", "Chosen/a_web.jpg"])
        XCTAssertTrue(report.entries.contains { ($0.note ?? "").contains("“Print” not written") },
                      "\(report.entries.map(\.note))")
    }

    func testAPlainBookmarkToTheStoredPathIsConfirmedOnlyOutsideTheSandbox() throws {
        let folderURL = root.appendingPathComponent("Same", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let folder = VariantFolder(path: folderURL.path, bookmark: try plainBookmark(folderURL))
        XCTAssertTrue(folder.resolution(sandboxEnforced: false).isConfirmed)
        XCTAssertFalse(folder.resolution(sandboxEnforced: true).isConfirmed)
        XCTAssertFalse(VariantFolder(path: folderURL.path).resolution(sandboxEnforced: false).isConfirmed,
                       "a path without a bookmark is asked for in the app")
    }

    func testSameFolderIgnoresTheSubfolder() async throws {
        let photo = try source("a.jpg")
        let pipeline = Pipeline(output: OutputSettings(format: .jpeg), extraOutputs: [
            OutputVariant(name: "Here", nameSuffix: "_here", subfolder: "left-over", destination: .sameFolder),
        ])
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(relative), ["out/a.jpg", "a_here.jpg"])
    }

    func testFolderDescriptionsForTheCommandLine() {
        let main = OutputMode.newFolder(URL(fileURLWithPath: "/out"))
        XCTAssertEqual(OutputVariant(nameSuffix: "_a").folderDescription(main: main), "/out")
        XCTAssertEqual(OutputVariant(nameSuffix: "_a", subfolder: "t").folderDescription(main: main), "/out/t")
        XCTAssertEqual(OutputVariant(nameSuffix: "_a").folderDescription(main: .overwrite), "next to each original")
        XCTAssertEqual(OutputVariant(nameSuffix: "_a", destination: .folder(VariantFolder(path: "/web")))
            .folderDescription(main: main), "/web")
        XCTAssertEqual(OutputVariant(nameSuffix: "_a", destination: .subfolder("thumbs")).folderDescription(main: main),
                       "“thumbs” next to each original")
    }
}
