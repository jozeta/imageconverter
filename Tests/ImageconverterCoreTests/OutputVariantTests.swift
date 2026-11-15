import XCTest
@testable import ImageconverterCore

/// Extra outputs: the model, suffix rules and lenient decoding.
final class OutputVariantTests: XCTestCase {
    private func variant(_ suffix: String, name: String = "Thumb") -> OutputVariant {
        OutputVariant(name: name, nameSuffix: suffix)
    }

    func testOldPipelineJSONDecodesWithoutExtraOutputs() throws {
        let json = #"{"schemaVersion":1,"steps":[],"output":{"format":"png"}}"#
        let pipeline = try JSONDecoder().decode(Pipeline.self, from: Data(json.utf8))
        XCTAssertEqual(pipeline.extraOutputs, [])
        XCTAssertEqual(pipeline.output.format, .png)
        XCTAssertTrue(pipeline.loadNotes.notes.isEmpty)
    }

    func testRoundTripKeepsEveryField() throws {
        var pipeline = Pipeline()
        pipeline.extraOutputs = [
            OutputVariant(name: "Thumbnail", settings: OutputSettings(format: .jpeg, quality: 0.6),
                          resize: .longestEdge(400), nameSuffix: "_thumb", subfolder: "thumbs/{date:yyyy}"),
            OutputVariant(name: "Web", settings: OutputSettings(format: .png), resize: .percent(150), nameSuffix: "@2x"),
            OutputVariant(name: "Full", settings: OutputSettings(format: .heic, compression: .maxSize(bytes: 90_000)),
                          resize: nil, nameSuffix: "-full"),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(pipeline)
        let decoded = try JSONDecoder().decode(Pipeline.self, from: data)
        XCTAssertEqual(decoded, pipeline)
        XCTAssertEqual(decoded.extraOutputs, pipeline.extraOutputs)
        // Encoding again gives the same bytes: the round trip is stable.
        XCTAssertEqual(try encoder.encode(decoded), data)
    }

    func testEmptyListRoundTrips() throws {
        let data = try JSONEncoder().encode(Pipeline())
        XCTAssertEqual(try JSONDecoder().decode(Pipeline.self, from: data).extraOutputs, [])
    }

    func testSuffixIsSanitisedLikeANamePart() {
        XCTAssertEqual(OutputVariant.sanitizedSuffix("_thumb"), "_thumb")
        XCTAssertEqual(OutputVariant.sanitizedSuffix(" a/b:c "), "a-b-c")
        XCTAssertEqual(OutputVariant.sanitizedSuffix("x\u{202E}y\u{0007}"), "xy")
        XCTAssertEqual(OutputVariant.sanitizedSuffix("   "), "")
        XCTAssertEqual(OutputVariant.sanitizedSuffix("\u{200B}"), "")
        XCTAssertEqual(OutputVariant.sanitizedSuffix(String(repeating: "a", count: 80)).count, OutputVariant.maxSuffixLength)
    }

    func testProblemsFlagEmptyDuplicateAndTooMany() {
        let list = [variant("_a"), variant(""), variant("_A"), variant(" _a ")]
            + (0..<6).map { variant("_\($0)") }
        let problems = OutputVariant.problems(in: list)
        XCTAssertNil(problems[list[0].id])
        XCTAssertEqual(problems[list[1].id], OutputVariant.emptySuffixProblem)
        XCTAssertEqual(problems[list[2].id], OutputVariant.duplicateSuffixProblem)
        XCTAssertEqual(problems[list[3].id], OutputVariant.duplicateSuffixProblem)
        XCTAssertNil(problems[list[7].id])
        XCTAssertEqual(problems[list[8].id], OutputVariant.tooManyProblem)
        XCTAssertEqual(problems[list[9].id], OutputVariant.tooManyProblem)
        XCTAssertTrue(OutputVariant.problems(in: [variant("_a"), variant("_b")]).isEmpty)
    }

    func testDecodeDropsInvalidOutputsWithANote() throws {
        let json = """
        {"extraOutputs":[
          {"name":"A","nameSuffix":"_a","settings":{"format":"jpeg"}},
          {"name":"Blank","nameSuffix":"  "},
          {"name":"Again","nameSuffix":"_A"},
          {"name":"Broken","nameSuffix":5},
          "not an object",
          {"name":"Big","nameSuffix":"_big","resize":{"longestEdge":{"_0":0}}}
        ]}
        """
        let pipeline = try JSONDecoder().decode(Pipeline.self, from: Data(json.utf8))
        // "Broken" has no readable suffix, so it decodes with an empty one and is left out too.
        XCTAssertEqual(pipeline.extraOutputs.map(\.name), ["A", "Big"])
        XCTAssertNil(pipeline.extraOutputs.last?.resize, "an out-of-range resize is dropped, the output kept")
        // Three left out for their suffix, one ("not an object") that couldn't be read at all.
        XCTAssertEqual(pipeline.loadNotes.notes.count, 4, "\(pipeline.loadNotes.notes)")
        XCTAssertTrue(pipeline.loadNotes.notes.contains("An extra output couldn't be read and was left out"))
        XCTAssertTrue(pipeline.loadNotes.notes.contains { $0.contains("Blank") })
    }

    func testUnreadableSettingsDropTheOutputWithANote() throws {
        let json = """
        {"extraOutputs":[
          {"name":"Future","nameSuffix":"_f","settings":{"format":"jpegxl"}},
          {"name":"Fine","nameSuffix":"_ok","settings":{"format":"png"}}
        ]}
        """
        let pipeline = try JSONDecoder().decode(Pipeline.self, from: Data(json.utf8))
        XCTAssertEqual(pipeline.extraOutputs.map(\.name), ["Fine"])
        XCTAssertEqual(pipeline.extraOutputs.first?.settings.format, .png)
        XCTAssertEqual(pipeline.loadNotes.notes, ["Extra output “Future” couldn't be read and was left out"])
    }

    func testRepeatedIDsAreRenewedNotDropped() throws {
        let id = "00000000-0000-4000-8000-000000000001"
        let json = """
        {"extraOutputs":[
          {"id":"\(id)","name":"A","nameSuffix":"_a"},
          {"id":"\(id)","name":"B","nameSuffix":"_b"},
          {"id":"\(id)","name":"C","nameSuffix":"_a"}
        ]}
        """
        let pipeline = try JSONDecoder().decode(Pipeline.self, from: Data(json.utf8))
        XCTAssertEqual(pipeline.extraOutputs.map(\.name), ["A", "B"])
        XCTAssertEqual(pipeline.extraOutputs.first?.id.uuidString, id, "the first keeps its id")
        XCTAssertEqual(Set(pipeline.extraOutputs.map(\.id)).count, 2)
        // Only the real problem is noted: C repeats A's suffix.
        XCTAssertEqual(pipeline.loadNotes.notes.count, 1)
        XCTAssertTrue(pipeline.loadNotes.notes[0].contains("“C”"), pipeline.loadNotes.notes[0])
    }

    func testDecodeKeepsAtMostEight() throws {
        var pipeline = Pipeline()
        pipeline.extraOutputs = (0..<10).map { variant("_\($0)") }
        let decoded = try JSONDecoder().decode(Pipeline.self, from: JSONEncoder().encode(pipeline))
        XCTAssertEqual(decoded.extraOutputs.count, OutputVariant.maxCount)
        XCTAssertEqual(decoded.loadNotes.notes.count, 2)
    }

    func testLoadNotesNeverMakePipelinesUnequal() {
        var lhs = Pipeline()
        lhs.loadNotes = PipelineLoadNotes(["something"])
        XCTAssertEqual(lhs, Pipeline())
    }

    func testResizeOptionsShrinkOnlyUnlessPercentAbove100() {
        XCTAssertFalse(VariantResize.longestEdge(400).resizeOptions.allowEnlarge)
        XCTAssertFalse(VariantResize.percent(50).resizeOptions.allowEnlarge)
        XCTAssertTrue(VariantResize.percent(150).resizeOptions.allowEnlarge)
        XCTAssertFalse(VariantResize.percent(0).isValid)
        XCTAssertFalse(VariantResize.maxWidth(0).isValid)
        XCTAssertTrue(VariantResize.maxHeight(1).isValid)
    }

    func testPresetFileCarriesExtraOutputs() throws {
        var pipeline = Pipeline()
        pipeline.extraOutputs = [variant("_t")]
        let preset = Preset(name: "With thumbs", pipeline: pipeline)
        let decoded = try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(decoded.pipeline.extraOutputs, pipeline.extraOutputs)
    }
}
