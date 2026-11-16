import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// Alt text pieces without a batch: the sanitiser, options, the blocking bridge and the system generator.
final class AltTextTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let altPath = "Iptc4xmpCore:AltTextAccessibility"

    private func altOptions(description: Bool = false) -> MetadataOptions {
        var options = MetadataOptions(isEnabled: true, removeLocation: false)
        options.generateAltText = true
        options.altTextAsDescription = description
        return options
    }

    private func run(_ url: URL, metadata: MetadataOptions, steps: [PipelineStep] = [],
                     format: OutputFormat = .jpeg, generator: any AltTextGenerator,
                     extraOutputs: [OutputVariant] = []) async throws -> (WrittenFile, BatchReport) {
        let pipeline = Pipeline(steps: steps, output: OutputSettings(format: format), metadata: metadata,
                                extraOutputs: extraOutputs)
        let out = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        let report = await BatchRunner.run([InputItem(source: url, relativeDirectory: "")], pipeline: pipeline,
                                           mode: .newFolder(out), altText: generator)
        XCTAssertEqual(report.failures, [])
        return (try WrittenFile(url: try XCTUnwrap(report.written.first)), report)
    }

    private func source(_ name: String = "a.jpg", type: UTType = .jpeg, width: Int = 120, height: Int = 80) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.noise(width: width, height: height), to: url, type: type)
        return url
    }

    // MARK: Sanitiser

    func testSanitiserStripsControlFormatAndBidiCharacters() {
        let raw = "A\u{0007} dog\u{202E} on\u{200B} the\u{2066} beach\u{FEFF}\u{E000}."
        XCTAssertEqual(AltText.sanitized(raw), "A dog on the beach.")
    }

    func testSanitiserCollapsesWhitespaceAndLineBreaks() {
        XCTAssertEqual(AltText.sanitized("  A cat\n\n sleeping\t on\u{2028}a  sofa.  "), "A cat sleeping on a sofa.")
    }

    func testSanitiserDropsQuotesAndImageOfLeadIns() {
        XCTAssertEqual(AltText.sanitized("\"A red bicycle.\""), "A red bicycle.")
        XCTAssertEqual(AltText.sanitized("\u{201C}Image of a red bicycle.\u{201D}"), "A red bicycle.")
        XCTAssertEqual(AltText.sanitized("A picture of two boats."), "Two boats.")
        XCTAssertEqual(AltText.sanitized("Photo of mountains at dawn."), "Mountains at dawn.")
        XCTAssertEqual(AltText.sanitized("Imagery of space."), "Imagery of space.")
    }

    func testSanitiserCapsAtAWordBoundary() throws {
        let words = Array(repeating: "lighthouse", count: 40).joined(separator: " ")
        let capped = try XCTUnwrap(AltText.sanitized(words))
        XCTAssertLessThanOrEqual(capped.count, AltText.maxLength)
        XCTAssertTrue(capped.hasSuffix("lighthouse"), capped)
        XCTAssertGreaterThan(capped.count, AltText.maxLength - 12)
        // Exactly at the limit before a space: nothing is lost.
        let exact = String(repeating: "a", count: 250) + " more"
        XCTAssertEqual(AltText.sanitized(exact)?.count, 250)
        // One long word: cut at the limit.
        XCTAssertEqual(AltText.sanitized(String(repeating: "x", count: 400))?.count, 250)
        // Grapheme clusters count as one character each.
        XCTAssertEqual(AltText.sanitized(String(repeating: "\u{1F600}", count: 300))?.count, 250)
    }

    func testSanitiserGivesNilForNothingUsable() {
        XCTAssertNil(AltText.sanitized(""))
        XCTAssertNil(AltText.sanitized(" \n\t\u{202E}\u{200B} "))
        XCTAssertNil(AltText.sanitized("\"\""))
    }

    func testEveryUnavailableReasonIsWorded() {
        let cases: [AltTextAvailability] = [.unsupportedOS, .deviceNotEligible, .appleIntelligenceNotEnabled,
                                            .modelNotReady, .noImageSupport]
        for availability in cases { XCTAssertFalse(availability.reason?.isEmpty ?? true, "\(availability)") }
        XCTAssertNil(AltTextAvailability.available.reason)
        XCTAssertEqual(AltTextAvailability.unsupportedOS.reason, "needs macOS 27 or later")
    }

    // MARK: Options

    func testOptionsDecodeLenientlyAndRoundTrip() throws {
        let old = try JSONDecoder().decode(MetadataOptions.self, from: Data(#"{"isEnabled":true}"#.utf8))
        XCTAssertFalse(old.generateAltText)
        XCTAssertFalse(old.altTextAsDescription)
        let unchanged = String(bytes: try JSONEncoder().encode(old), encoding: .utf8) ?? ""
        XCTAssertFalse(unchanged.contains("AltText"), "files that don't use it are written as before")
        let wrong = try JSONDecoder().decode(MetadataOptions.self, from: Data(#"{"generateAltText":"yes"}"#.utf8))
        XCTAssertFalse(wrong.generateAltText)
        let options = altOptions(description: true)
        let decoded = try JSONDecoder().decode(MetadataOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
        XCTAssertTrue(decoded.generateAltText && decoded.altTextAsDescription)
        var generated = options
        generated.generatedAltText = "never saved"
        let saved = String(bytes: try JSONEncoder().encode(generated), encoding: .utf8) ?? ""
        XCTAssertFalse(saved.contains("never saved"))
    }

    func testTemplatesTurnTheAltTextSwitchesOnButNeverOff() {
        let template = MetadataTemplate(name: "Alt", payload: altOptions(description: true))
        let applied = MetadataTemplates.apply(template, to: MetadataOptions())
        XCTAssertTrue(applied.generateAltText && applied.altTextAsDescription)
        let off = MetadataTemplate(name: "Off", payload: MetadataOptions(isEnabled: true))
        XCTAssertTrue(MetadataTemplates.apply(off, to: altOptions()).generateAltText)
    }

    func testSummaryMentionsAltText() {
        XCTAssertTrue(altOptions().summary.contains("alt text"))
        XCTAssertTrue(altOptions(description: true).summary.contains("alt text (also description)"))
    }

    // MARK: The batch's blocking bridge

    /// As many waiting workers as a batch that generates alt text runs, each holding a cooperative thread, with a
    /// model call that needs the global queues (a sleep, a continuation resumed on a global queue): all answered.
    func testBatchWorkersWaitingNeverStarveTheGeneration() async throws {
        struct GlobalQueueGenerator: AltTextGenerator {
            var availability: AltTextAvailability { .available }
            func generate(for image: CGImage) async throws -> String {
                try await Task.sleep(nanoseconds: 1_000_000)
                await withCheckedContinuation { continuation in DispatchQueue.global().async { continuation.resume() } }
                return "Done."
            }
        }
        let workers = AltText.batchWorkers
        XCTAssertEqual(workers, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        let image = TestImages.make(width: 20, height: 20)
        let started = Date()
        let outcomes = await withTaskGroup(of: [AltTextOutcome?].self) { group -> [AltTextOutcome?] in
            for _ in 0..<workers {
                // Each blocks a cooperative thread, as the batch's synchronous workers do, for three items in a row.
                group.addTask {
                    (0..<3).map { _ in try? AltText.generateBlocking(for: image, with: GlobalQueueGenerator(), timeout: 10) }
                }
            }
            var all: [AltTextOutcome?] = []
            for await outcome in group { all += outcome }
            return all
        }
        XCTAssertEqual(outcomes.count, workers * 3)
        XCTAssertTrue(outcomes.allSatisfy { $0 == .text("Done.") }, "\(outcomes)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testBatchThatGeneratesRunsAtMostHalfTheCores() async throws {
        let urls = try (0..<6).map { try source("n\($0).jpg") }
        let active = ActiveCounter()
        var hooks = BatchHooks()
        hooks.altText = FakeAltTextGenerator()
        hooks.beforeEncode = { _, _ in active.enter(); Thread.sleep(forTimeInterval: 0.05); active.leave() }
        let pipeline = Pipeline(steps: [rotate], output: OutputSettings(format: .jpeg), metadata: altOptions())
        let out = root.appendingPathComponent("out", isDirectory: true)
        let report = await BatchRunner.run(urls.map { InputItem(source: $0, relativeDirectory: "") }, pipeline: pipeline,
                                           mode: .newFolder(out), concurrency: 64, hooks: hooks)
        XCTAssertEqual(report.written.count, 6)
        XCTAssertLessThanOrEqual(active.peak, AltText.batchWorkers)
    }

    func testCancelledBatchStopsWaiting() async throws {
        let image = TestImages.make(width: 20, height: 20)
        let task = Task.detached { () -> Result<AltTextOutcome, Error> in
            Result { try AltText.generateBlocking(for: image, with: FakeAltTextGenerator(.hang(seconds: 10)), timeout: 20) }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        task.cancel()
        let result = await task.value
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    // MARK: The system generator

    /// Only reads the availability; never asks the real model (it isn't ready on the development Mac, and asking
    /// must never make macOS download anything).
    func testSystemGeneratorReportsAvailabilityWithoutGenerating() {
        let availability = SystemAltTextGenerator.shared.availability
        if !SystemAltTextGenerator.isCompiledIn {
            XCTAssertEqual(availability, .unsupportedOS)
        } else if #unavailable(macOS 27) {
            XCTAssertEqual(availability, .unsupportedOS)
        }
        XCTAssertEqual(availability.reason == nil, availability == .available)
    }

    /// Only Apple's on-device model: the server model class must not appear anywhere in the sources.
    func testSourcesNeverNameTheServerModel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        let banned = ["Private" + "CloudCompute", "Private" + "Cloud" + "Compute".lowercased()]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            if banned.contains(where: text.contains) { offenders.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(scanned, 50)
        XCTAssertEqual(offenders, [])
    }

    private var rotate: PipelineStep { PipelineStep(operation: .rotateFlip(RotateFlipOptions(rotation: .cw90))) }
}
