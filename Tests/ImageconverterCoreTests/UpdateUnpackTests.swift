import Security
import XCTest
@testable import ImageconverterCore

/// The unpack watchdog (a zip can declare far smaller sizes than `ditto` writes), signature status wording, stale
/// install leftovers and quarantine removal. Temp folders only; no network.
final class UpdateUnpackTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("update-unpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let plenty: @Sendable (URL) -> Int64? = { _ in 1 << 40 }

    private func limits(maxUnpacked: Int64) -> UpdatePackage.Limits {
        UpdatePackage.Limits(maxEntries: 100, maxUncompressedBytes: maxUnpacked, maxListingBytes: 1 << 20,
                             unpackMargin: 0, minFreeBytes: 2 << 30, pollInterval: 0.05)
    }

    private func lyingZip(realSize: Int, declared: UInt32?) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).zip")
        try TestZip.write([TestZip.Entry(name: "imageconverter.app/"),
                           TestZip.Entry(name: "imageconverter.app/big", data: Data(count: realSize), declaredSize: declared)],
                          to: url)
        return url
    }

    func testDefaultsIncludeTheWatchdog() {
        XCTAssertEqual(UpdatePackage.Limits.standard.minFreeBytes, 2 << 30)
        XCTAssertGreaterThan(UpdatePackage.Limits.standard.unpackMargin, 0)
        XCTAssertLessThanOrEqual(UpdatePackage.Limits.standard.unpackMargin, 128 << 20)
    }

    func testHonestHandWrittenZipUnpacks() throws {
        let zip = try lyingZip(realSize: 300_000, declared: nil)
        let listing = try UpdatePackage.listEntries(of: zip)
        XCTAssertEqual(listing.uncompressedBytes, 300_000)
        let folder = root.appendingPathComponent("honest")
        try UpdatePackage.unpack(zip, into: folder, limits: limits(maxUnpacked: 1 << 20), freeSpace: plenty)
        let size = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("imageconverter.app/big").path)[.size]
        XCTAssertEqual(size as? Int, 300_000)
    }

    func testZipThatDeclaresLessThanItHoldsIsStopped() throws {
        // Declares 10 bytes, inflates to 20 MB: the listing passes, the unpack must not.
        let zip = try lyingZip(realSize: 20 << 20, declared: 10)
        XCTAssertEqual(try UpdatePackage.listEntries(of: zip).uncompressedBytes, 10)
        let folder = root.appendingPathComponent("lying")
        XCTAssertThrowsError(try UpdatePackage.unpack(zip, into: folder, limits: limits(maxUnpacked: 1 << 20), freeSpace: plenty)) {
            guard case .badPackage(let reason)? = $0 as? UpdateError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("too large when unpacked"), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the partial unpack is deleted")
    }

    /// A ditto zip of `imageconverter.app/f` (3 bytes) whose resource fork is `forkSize` bytes, stored by ditto as the
    /// AppleDouble entry `imageconverter.app/._f`.
    private func forkZip(forkSize: Int) throws -> URL {
        let source = root.appendingPathComponent("src-\(UUID().uuidString)/imageconverter.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("f")
        try Data("abc".utf8).write(to: file)
        let fork = Data(count: forkSize)
        XCTAssertEqual(fork.withUnsafeBytes { setxattr(file.path, "com.apple.ResourceFork", $0.baseAddress, fork.count, 0, 0) }, 0)
        let zip = root.appendingPathComponent("\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return zip
    }

    func testResourceForkThatDeclaresLessThanItHoldsIsStopped() throws {
        // `._f` declares 163 bytes but carries a 20 MB resource fork, which ditto writes into `f`'s fork, invisible to
        // the data size.
        let zip = try forkZip(forkSize: 20 << 20)
        try TestZip.patchDeclaredSize(of: "imageconverter.app/._f", in: zip, to: 163)
        XCTAssertLessThan(try UpdatePackage.listEntries(of: zip).uncompressedBytes, 1000)
        let folder = root.appendingPathComponent("rf")
        XCTAssertThrowsError(try UpdatePackage.unpack(zip, into: folder, limits: limits(maxUnpacked: 1 << 20), freeSpace: plenty)) {
            guard case .badPackage(let reason)? = $0 as? UpdateError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("too large when unpacked"), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAppleDoubleEntriesStillUnpack() throws {
        // Real release zips carry `._` entries; a small fork unpacks and the tree matches the listing.
        let zip = try forkZip(forkSize: 4096)
        let folder = root.appendingPathComponent("rf-small")
        try UpdatePackage.unpack(zip, into: folder, limits: limits(maxUnpacked: 1 << 20), freeSpace: plenty)
        XCTAssertNil(UpdatePackage.unpackedTreeProblem(in: folder, listing: try UpdatePackage.listEntries(of: zip)))
        let fork = getxattr(folder.appendingPathComponent("imageconverter.app/f").path, "com.apple.ResourceFork", nil, 0, 0, 0)
        XCTAssertEqual(fork, 4096, "ditto restored the resource fork")
    }

    func testDropInFreeSpaceCountsAsWritten() throws {
        // The folder stays small, but the volume loses more than the cap (forks, xattrs, anything else).
        let folder = root.appendingPathComponent("drop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let calls = LockedCounter()
        let script = "while true; do sleep 0.02; done"
        XCTAssertThrowsError(try UpdatePackage.runWatched("/bin/sh", ["-c", script], folder: folder,
                                                          watch: .init(maxBytes: 1 << 20, minFreeBytes: 0, interval: 0.05),
                                                          freeSpace: { _ in calls.next() > 2 ? (1 << 40) - (8 << 20) : 1 << 40 })) {
            guard case .badPackage(let reason)? = $0 as? UpdateError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("too large"), reason)
        }
    }

    func testNamesDittoWritesMustBeTheListedOnes() throws {
        // The central directory (zipinfo) says one name, the local header (ditto) another.
        for local in ["imageconverter.app/bbbb", "../../escaped-proof", "/escaped-abs"] {
            let url = root.appendingPathComponent("\(UUID().uuidString).zip")
            try TestZip.write([TestZip.Entry(name: "imageconverter.app/"),
                               TestZip.Entry(name: "imageconverter.app/aaaa", data: Data("x".utf8), localName: local)], to: url)
            let listing = try UpdatePackage.listEntries(of: url)
            XCTAssertNil(UpdatePackage.entryProblem(names: listing.names, symlinks: listing.symlinks), "the listing alone looks fine")
            let folder = root.appendingPathComponent("diff-\(UUID().uuidString)")
            try UpdatePackage.unpack(url, into: folder, limits: limits(maxUnpacked: 1 << 20), freeSpace: plenty)
            XCTAssertNotNil(UpdatePackage.unpackedTreeProblem(in: folder, listing: listing), local)
            XCTAssertThrowsError(try UpdatePackage.prepare(zip: url, expectedSHA256: UpdatePackage.sha256(of: url),
                                                           version: AppVersion("9.9.9")!, into: root.appendingPathComponent("p-\(UUID())"),
                                                           requirement: "identifier \"x\"", limits: limits(maxUnpacked: 1 << 20)))
        }
        let outside = root.deletingLastPathComponent().appendingPathComponent("escaped-proof")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testWatchdogStopsAToolThatKeepsWriting() throws {
        let folder = root.appendingPathComponent("writer")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = Date()
        // Writes 256 KB every 20 ms without end; only the watchdog stops it.
        let script = "while true; do head -c 262144 /dev/zero >> \"$1/out\"; sleep 0.02; done"
        XCTAssertThrowsError(try UpdatePackage.runWatched("/bin/sh", ["-c", script, "sh", folder.path], folder: folder,
                                                          watch: .init(maxBytes: 2 << 20, minFreeBytes: 0, interval: 0.05),
                                                          freeSpace: plenty)) {
            guard case .badPackage(let reason)? = $0 as? UpdateError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("too large"), reason)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testWatchdogStopsWhenTheDiskFillsUp() throws {
        let folder = root.appendingPathComponent("disk")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = LockedCounter()
        let script = "while true; do head -c 4096 /dev/zero >> \"$1/out\"; sleep 0.02; done"
        // Plenty of space at the start, then it runs out.
        XCTAssertThrowsError(try UpdatePackage.runWatched("/bin/sh", ["-c", script, "sh", folder.path], folder: folder,
                                                          watch: .init(maxBytes: 1 << 30, minFreeBytes: 2 << 30, interval: 0.05),
                                                          freeSpace: { _ in free.next() > 3 ? 1 << 20 : 1 << 40 })) {
            guard case .badPackage(let reason)? = $0 as? UpdateError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("disk space"), reason)
        }
    }

    func testTooLittleFreeSpaceIsRefusedBeforeUnpacking() throws {
        let zip = try lyingZip(realSize: 1000, declared: nil)
        let folder = root.appendingPathComponent("full")
        XCTAssertThrowsError(try UpdatePackage.unpack(zip, into: folder, limits: limits(maxUnpacked: 1 << 20),
                                                      freeSpace: { _ in 1 << 30 }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Signature wording

    func testSignatureStatusWording() {
        for unavailable in [errSecNetworkFailure, errSecOCSPUnavailable, errSecOCSPStatusUnrecognized, errSecCRLServerDown] {
            XCTAssertEqual(UpdateSignature.error(forStatus: unavailable), .signatureUnconfirmed, "\(unavailable)")
        }
        for refused in [errSecCSReqFailed, errSecCertificateRevoked, errSecCSRevokedNotarization, OSStatus(-2_147_409_652),
                        errSecCSUnsigned] {
            XCTAssertEqual(UpdateSignature.error(forStatus: refused), .signatureRejected, "\(refused)")
        }
        XCTAssertEqual(UpdateError.signatureUnconfirmed.message,
                       "Couldn't confirm the update's signature right now. Try again when you're online.")
    }

    // MARK: Leftovers and quarantine

    func testStaleInstallLeftoversAreRemoved() throws {
        let installed = root.appendingPathComponent("imageconverter.app")
        let names = [".imageconverter-update-1.app", ".imageconverter-old-2.app", ".other.app", "imageconverter-old-3.app",
                     ".imageconverter-update-4.txt"]
        for name in names + ["imageconverter.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        UpdateReplacer.removeLeftovers(beside: installed)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(left, [".imageconverter-update-4.txt", ".other.app", "imageconverter-old-3.app", "imageconverter.app"])
    }

    func testQuarantineIsRemovedFromTheWholeBundle() throws {
        let app = root.appendingPathComponent("imageconverter.app")
        let file = app.appendingPathComponent("Contents/MacOS/imageconverter")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/link"), withDestinationURL: file)
        let value = Data("0086;00000000;imageconverter;".utf8)
        for url in [app, file] {
            _ = value.withUnsafeBytes { setxattr(url.path, UpdateQuarantine.attribute, $0.baseAddress, value.count, 0, 0) }
        }
        XCTAssertTrue(UpdateQuarantine.isQuarantined(app))
        try UpdateQuarantine.strip(app)
        XCTAssertFalse(UpdateQuarantine.isQuarantined(app))
    }
}

/// A thread-safe counter for closures called from the watchdog.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
