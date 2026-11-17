import XCTest
@testable import ImageconverterCore

/// Commits never replace a file that appeared after planning, and concurrent runs never plan the same name.
final class ExclusiveCommitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func png(_ url: URL, width: Int = 20) throws -> URL {
        try TestImages.write(TestImages.make(width: width, height: 20), to: url, type: .png)
        return url
    }

    private var pngPipeline: Pipeline { Pipeline(output: OutputSettings(format: .png)) }

    /// Bug B1: two runs at once, six same-named files each, into one folder: every output kept, none replaced.
    func testConcurrentRunsNeverReplace() async throws {
        for round in 0..<20 {
            let base = try folder("round\(round)")
            let out = base.appendingPathComponent("out", isDirectory: true)
            var sets: [[URL]] = [[], []]
            for run in 0..<2 {
                let source = base.appendingPathComponent("src\(run)", isDirectory: true)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                for index in 0..<6 {
                    sets[run].append(try png(source.appendingPathComponent("img\(index).png"), width: 30 + run))
                }
            }
            let inputs = sets
            async let first = BatchRunner.run(InputCollector.collect(inputs[0]), pipeline: pngPipeline,
                                              mode: .newFolder(out))
            async let second = BatchRunner.run(InputCollector.collect(inputs[1]), pipeline: pngPipeline,
                                               mode: .newFolder(out))
            let (one, two) = await (first, second)
            XCTAssertEqual(one.failures + two.failures, [], "round \(round)")
            let files = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { !$0.hasPrefix(".") }
            XCTAssertEqual(files.count, 12, "round \(round): \(files.sorted())")
            let written = one.written + two.written
            XCTAssertEqual(Set(written.map(\.standardizedFileURL.path)).count, 12, "round \(round)")
            for (report, width) in [(one, 30), (two, 31)] {
                for url in report.written {
                    XCTAssertEqual(ImageLoader.pixelSize(of: url)?.width, width, "\(url.lastPathComponent) is its own")
                }
            }
        }
    }

    /// A file that appears at the planned name after planning is never replaced: the output takes `_2`.
    func testCommitTakesNextFreeNameWhenTaken() async throws {
        let source = try png(try folder("in").appendingPathComponent("a.png"))
        let out = try folder("out")
        let squatter = out.appendingPathComponent("a.png")
        var hooks = BatchHooks()
        hooks.beforeEncode = { _, _ in try Data("other".utf8).write(to: squatter) }
        let report = await BatchRunner.run(InputCollector.collect([source]), pipeline: pngPipeline,
                                           mode: .newFolder(out), hooks: hooks)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a_2.png"])
        XCTAssertEqual(report.entries.map(\.destination.lastPathComponent), ["a_2.png"])
        XCTAssertEqual(try Data(contentsOf: squatter), Data("other".utf8))
        XCTAssertNotNil(ImageLoader.pixelSize(of: out.appendingPathComponent("a_2.png")))
    }

    /// An extra output whose planned name is taken after planning also takes the next free name.
    func testExtraOutputTakesNextFreeNameWhenTaken() async throws {
        let source = try png(try folder("in").appendingPathComponent("a.png"))
        let out = try folder("out")
        var pipeline = pngPipeline
        pipeline.extraOutputs = [OutputVariant(settings: OutputSettings(format: .png), resize: nil, nameSuffix: "_small")]
        let squatter = out.appendingPathComponent("a_small.png")
        var hooks = BatchHooks()
        hooks.beforeEncode = { _, _ in try Data("other".utf8).write(to: squatter) }
        let report = await BatchRunner.run(InputCollector.collect([source]), pipeline: pipeline,
                                           mode: .newFolder(out), hooks: hooks)
        XCTAssertEqual(report.extraFailures, [])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.png", "a_small_2.png"])
        XCTAssertEqual(try Data(contentsOf: squatter), Data("other".utf8))
    }

    /// Overwrite mode with a format change: a file appearing at the new name is kept, the converted file takes
    /// `_2`, and the original is trashed only once that file is in place.
    func testOverwriteNeverTrashesWhenReplaced() async throws {
        let source = try png(try folder("in").appendingPathComponent("a.png"))
        let squatter = source.deletingLastPathComponent().appendingPathComponent("a.jpg")
        let trashed = LockedLog<URL>()
        var hooks = BatchHooks()
        hooks.beforeEncode = { _, _ in try Data("other".utf8).write(to: squatter) }
        let report = await BatchRunner.run(InputCollector.collect([source]),
                                           pipeline: Pipeline(output: OutputSettings(format: .jpeg)),
                                           mode: .overwrite, trash: { url in
                                               // The new file is already in place when the original goes.
                                               XCTAssertNotNil(ImageLoader.pixelSize(
                                                   of: url.deletingLastPathComponent().appendingPathComponent("a_2.jpg")))
                                               trashed.append(url)
                                           }, hooks: hooks)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a_2.jpg"])
        XCTAssertEqual(try Data(contentsOf: squatter), Data("other".utf8))
        XCTAssertEqual(trashed.values, [source])
    }

    /// The commit itself: an existing destination is never replaced, and the URL written is returned.
    func testCommitReturnsWrittenURL() throws {
        let out = try folder("out")
        let item = InputItem(source: root.appendingPathComponent("src.png"), relativeDirectory: "")
        let destination = out.appendingPathComponent("a.png")
        try Data("first".utf8).write(to: destination)
        let plan = PlannedOutput(item: item, destination: destination, replacesSource: false, trashesSource: false)
        let written = try FileCommitter.commit(Data("second".utf8), for: plan)
        XCTAssertEqual(written.lastPathComponent, "a_2.png")
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: written), Data("second".utf8))
    }

    /// Eight commits of one plan at once (no planner involved): each lands under its own name, none replaced.
    func testConcurrentCommitsOfOneNameAllKept() throws {
        for round in 0..<20 {
            let out = try folder("commits\(round)")
            let item = InputItem(source: root.appendingPathComponent("src.png"), relativeDirectory: "")
            let plan = PlannedOutput(item: item, destination: out.appendingPathComponent("a.png"),
                                     replacesSource: false, trashesSource: false)
            let written = LockedLog<URL>()
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                if let url = try? FileCommitter.commit(Data("file \(index)".utf8), for: plan) { written.append(url) }
            }
            XCTAssertEqual(Set(written.values.map(\.lastPathComponent)).count, 8, "round \(round)")
            let contents = try written.values.map { try String(contentsOf: $0, encoding: .utf8) }
            XCTAssertEqual(Set(contents).count, 8, "round \(round): every file keeps its own content")
        }
    }

    func testPlannedDestinationsClaimOnce() {
        let url = root.appendingPathComponent("x.png")
        XCTAssertTrue(PlannedDestinations.claim(url))
        XCTAssertFalse(PlannedDestinations.claim(url))
        PlannedDestinations.release(url)
        XCTAssertTrue(PlannedDestinations.claim(url))
        PlannedDestinations.release(url)
    }

    /// A finished run holds no destination any more, so a later run plans the same names again.
    func testRunReleasesItsDestinations() async throws {
        let source = try png(try folder("in").appendingPathComponent("a.png"))
        let out = try folder("out")
        let report = await BatchRunner.run(InputCollector.collect([source]), pipeline: pngPipeline,
                                           mode: .newFolder(out))
        XCTAssertEqual(report.written.count, 1)
        XCTAssertFalse(PlannedDestinations.isClaimed(out.appendingPathComponent("a.png")))
        XCTAssertFalse(PlannedDestinations.isClaimed(out.appendingPathComponent("a_2.png")))
    }

    // MARK: Volumes without RENAME_EXCL (exFAT)

    private let unsupported: FileCommitter.ExclusiveRename = { _, _ in ENOTSUP }

    func testFallbackPlacesFileWhenNameIsFree() throws {
        let out = try folder("out")
        let temp = out.appendingPathComponent("temp")
        try Data("new".utf8).write(to: temp)
        let destination = out.appendingPathComponent("a.png")
        XCTAssertTrue(try FileCommitter.renameExclusive(temp, to: destination, exclusiveRename: unsupported))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testFallbackNeverReplacesATakenName() throws {
        let out = try folder("out")
        let temp = out.appendingPathComponent("temp")
        try Data("new".utf8).write(to: temp)
        let destination = out.appendingPathComponent("a.png")
        try Data("keep".utf8).write(to: destination)
        XCTAssertFalse(try FileCommitter.renameExclusive(temp, to: destination, exclusiveRename: unsupported))
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: temp), Data("new".utf8))
    }

    func testFallbackRemovesItsPlaceholderWhenTheRenameFails() throws {
        let out = try folder("out")
        let destination = out.appendingPathComponent("a.png")
        XCTAssertThrowsError(try FileCommitter.renameExclusive(out.appendingPathComponent("missing"), to: destination,
                                                               exclusiveRename: unsupported))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testEINVALAlsoFallsBack() throws {
        let out = try folder("out")
        let temp = out.appendingPathComponent("temp")
        try Data("new".utf8).write(to: temp)
        let destination = out.appendingPathComponent("a.png")
        XCTAssertTrue(try FileCommitter.renameExclusive(temp, to: destination, exclusiveRename: { _, _ in EINVAL }))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }

    /// A real exFAT volume (a 16 MB disk image): commits work, and a taken name gets `_2`. Skipped without hdiutil.
    func testCommitsOnExFATVolume() throws {
        let image = root.appendingPathComponent("exfat.dmg")
        let mount = root.appendingPathComponent("mnt", isDirectory: true)
        guard Self.hdiutil(["create", "-quiet", "-size", "16m", "-fs", "ExFAT", "-volname", "ictest", "-o", image.path]),
              Self.hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path]) else {
            throw XCTSkip("hdiutil couldn't make an exFAT disk image here")
        }
        defer { _ = Self.hdiutil(["detach", "-quiet", "-force", mount.path]) }
        let item = InputItem(source: root.appendingPathComponent("src.png"), relativeDirectory: "")
        let plan = PlannedOutput(item: item, destination: mount.appendingPathComponent("a.png"),
                                 replacesSource: false, trashesSource: false)
        let first = try FileCommitter.commit(Data("first".utf8), for: plan)
        let second = try FileCommitter.commit(Data("second".utf8), for: plan)
        XCTAssertEqual([first.lastPathComponent, second.lastPathComponent], ["a.png", "a_2.png"])
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    private static func hdiutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
