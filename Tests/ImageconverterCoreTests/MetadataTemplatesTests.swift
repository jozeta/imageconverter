import XCTest
@testable import ImageconverterCore

final class MetadataTemplatesTests: XCTestCase {
    private var directory: URL!
    private var store: MetadataTemplateStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdtemplates-\(UUID().uuidString)", isDirectory: true)
        store = MetadataTemplateStore.metadata(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func template(_ name: String = "Mine", _ options: MetadataOptions = MetadataOptions(removeCamera: true))
        -> MetadataTemplate {
        MetadataTemplate(name: name, options: options)
    }

    private func writeRaw(_ data: Data, name: String = UUID().uuidString + ".json") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testRoundTrip() throws {
        var options = MetadataOptions(removeCamera: true, copyright: "© Me")
        options.keywords = ["a", "b"]
        options.custom = [MetadataField(namespace: .exif, key: "UserComment", value: "hi")]
        let saved = template("Mine", options)
        try store.save(saved)
        let loaded = store.load().templates.first { $0.id == saved.id }
        XCTAssertEqual(loaded?.options, options)
        XCTAssertEqual(loaded?.name, "Mine")
        XCTAssertEqual(loaded?.isBuiltIn, false)
    }

    func testBuiltInsFirst() {
        let names = store.load().templates.prefix(3).map(\.name)
        XCTAssertEqual(names, ["Privacy (remove location, camera, author)",
                               "Web (remove all, keep copyright)", "Remove everything"])
        let all = MetadataTemplates.builtIns
        XCTAssertEqual(all[0].options.location, .remove)
        XCTAssertTrue(all[0].options.removeCamera && all[0].options.removeAuthor)
        XCTAssertTrue(all[1].options.removeAll)
        XCTAssertEqual(all[1].options.keepWhenRemovingAll, [.copyright])
        XCTAssertTrue(all[2].options.removeAll)
        XCTAssertTrue(all[2].options.keepWhenRemovingAll.isEmpty)
        XCTAssertTrue(all.allSatisfy { $0.options.isEnabled && $0.isBuiltIn })
    }

    func testBuiltInsReadOnly() {
        let builtIn = MetadataTemplates.builtIns[0]
        XCTAssertThrowsError(try store.save(builtIn)) { XCTAssertEqual($0 as? PresetError, .builtInReadOnly) }
        XCTAssertThrowsError(try store.delete(id: builtIn.id)) {
            XCTAssertEqual($0 as? PresetError, .builtInReadOnly)
        }
        var copy = template("Mine")
        copy.id = builtIn.id
        XCTAssertThrowsError(try store.save(copy))
    }

    func testDuplicateNameRejected() throws {
        try store.save(template("Mine"))
        XCTAssertThrowsError(try store.save(template("  MINE "))) {
            XCTAssertEqual($0 as? PresetError, .duplicateName)
        }
        XCTAssertThrowsError(try store.save(template("remove everything"))) {
            XCTAssertEqual($0 as? PresetError, .duplicateName)
        }
    }

    func testRenameAndDelete() throws {
        let saved = template("Mine")
        try store.save(saved)
        try store.rename(id: saved.id, to: "Other")
        XCTAssertEqual(store.load().templates.first { $0.id == saved.id }?.name, "Other")
        try store.delete(id: saved.id)
        XCTAssertNil(store.load().templates.first { $0.id == saved.id })
        XCTAssertNoThrow(try store.delete(id: saved.id))
    }

    func testRejectsOversizedSymlinkAndGarbage() throws {
        let big = UUID(), link = UUID(), garbage = UUID(), wrongType = UUID(), newer = UUID()
        _ = try writeRaw(Data(repeating: 0x20, count: StoredFile.maxFileSize + 10), name: "\(big).json")
        _ = try writeRaw(Data("not json".utf8), name: "\(garbage).json")
        _ = try writeRaw(Data(#"{"schemaVersion":1,"id":"\#(wrongType)","name":"x","payload":5}"#.utf8),
                         name: "\(wrongType).json")
        _ = try writeRaw(Data(#"{"schemaVersion":9,"id":"\#(newer)","name":"x","payload":{}}"#.utf8),
                         name: "\(newer).json")
        let target = try writeRaw(Data("{}".utf8), name: "target.txt")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("\(link).json"), withDestinationURL: target)
        let result = store.load()
        XCTAssertEqual(result.templates.count, MetadataTemplates.builtIns.count)
        let reasons = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.file, $0.reason) })
        XCTAssertEqual(reasons["\(big).json"], PresetError.tooLarge.reason(noun: "template"))
        XCTAssertEqual(reasons["\(garbage).json"], PresetError.invalidJSON.reason(noun: "template"))
        XCTAssertEqual(reasons["\(wrongType).json"], PresetError.invalidStructure.reason(noun: "template"))
        XCTAssertEqual(reasons["\(newer).json"], PresetError.unsupportedVersion(9).reason(noun: "template"))
        XCTAssertNotNil(reasons["\(link).json"])
        XCTAssertFalse(reasons.values.contains { $0.contains("preset") })
    }

    func testRejectsIDMismatchAndBuiltInID() throws {
        let fileID = UUID()
        let builtIn = MetadataTemplates.builtIns[0].id
        _ = try writeRaw(Data(#"{"schemaVersion":1,"id":"\#(UUID())","name":"a","payload":{}}"#.utf8),
                         name: "\(fileID).json")
        _ = try writeRaw(Data(#"{"schemaVersion":1,"id":"\#(builtIn)","name":"b","payload":{}}"#.utf8),
                         name: "\(builtIn).json")
        let result = store.load()
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertEqual(result.templates.count, MetadataTemplates.builtIns.count)
    }

    // MARK: apply

    func testApplyMergesOnlySetFields() {
        var current = MetadataOptions(isEnabled: false, isIncluded: false, removeLocation: false, artist: "Me",
                                      copyright: "© Old")
        current.title = "Keep me"
        current.removeThumbnail = true
        current.keywords = ["old"]
        current.dateTaken = .shift(seconds: 60)
        current.setFileDates = true
        current.custom = [MetadataField(namespace: .exif, key: "UserComment", value: "old")]

        var set = MetadataOptions(removeLocation: false)   // everything "keep"
        set.copyright = "© New"
        set.removeCamera = true
        set.custom = [MetadataField(namespace: .exif, key: "UserComment", value: "new"),
                      MetadataField(namespace: .exif, key: "ImageDescription", value: "d")]
        let merged = MetadataTemplates.apply(MetadataTemplate(name: "t", options: set), to: current)

        XCTAssertTrue(merged.isEnabled && merged.isIncluded)
        XCTAssertEqual(merged.copyright, "© New")                 // set -> overrides
        XCTAssertEqual(merged.artist, "Me")                       // nil -> stays
        XCTAssertEqual(merged.title, "Keep me")
        XCTAssertTrue(merged.removeCamera)                        // true -> on
        XCTAssertTrue(merged.removeThumbnail)                     // false never turns a removal off
        XCTAssertEqual(merged.location, .keep)                    // .keep -> stays
        XCTAssertEqual(merged.keywords, ["old"])                  // nil -> stays
        XCTAssertEqual(merged.dateTaken, .shift(seconds: 60))     // .keep -> stays
        XCTAssertTrue(merged.setFileDates)
        XCTAssertEqual(merged.custom.count, 2)
        XCTAssertEqual(merged.custom.first { $0.key == "UserComment" }?.value, "new")
    }

    func testApplyEmptyStringClearsAndEmptyAddKeywordsStay() {
        var current = MetadataOptions(artist: "Me")
        current.keywords = ["x"]
        var set = MetadataOptions(removeLocation: false)
        set.artist = ""
        set.keywords = []                       // add mode with nothing: leaves keywords
        XCTAssertEqual(MetadataTemplates.apply(MetadataTemplate(name: "t", options: set), to: current).keywords, ["x"])
        XCTAssertEqual(MetadataTemplates.apply(MetadataTemplate(name: "t", options: set), to: current).artist, "")
        set.keywordsMode = .replace             // replace with nothing clears them
        let cleared = MetadataTemplates.apply(MetadataTemplate(name: "t", options: set), to: current)
        XCTAssertEqual(cleared.keywords, [])
        XCTAssertEqual(cleared.keywordsMode, .replace)
        set.keywords = ["n"]
        set.keywordsMode = .add
        let added = MetadataTemplates.apply(MetadataTemplate(name: "t", options: set), to: current)
        XCTAssertEqual(added.keywords, ["n"])
        XCTAssertEqual(added.keywordsMode, .add)
    }

    func testApplyLocationAndDateOverride() {
        var current = MetadataOptions(removeLocation: true)
        current.dateTaken = .shift(seconds: 5)
        var set = MetadataOptions(location: .set(latitude: 1, longitude: 2, altitude: nil))
        set.dateTaken = .shift(seconds: 9)
        let merged = MetadataTemplates.apply(MetadataTemplate(name: "t", options: set), to: current)
        XCTAssertEqual(merged.location, .set(latitude: 1, longitude: 2, altitude: nil))
        XCTAssertEqual(merged.dateTaken, .shift(seconds: 9))
    }

    func testApplyRemoveAllTemplates() {
        var current = MetadataOptions(removeLocation: false)
        current.keepWhenRemovingAll = [.location, .author]
        let web = MetadataTemplates.apply(MetadataTemplates.builtIns[1], to: current)
        XCTAssertTrue(web.removeAll)
        XCTAssertEqual(web.keepWhenRemovingAll, [.copyright])    // the template's keep list defines it
        let all = MetadataTemplates.apply(MetadataTemplates.builtIns[2], to: web)
        XCTAssertTrue(all.keepWhenRemovingAll.isEmpty)
        // A template that doesn't remove everything leaves the current choice alone.
        let privacy = MetadataTemplates.apply(MetadataTemplates.builtIns[0], to: web)
        XCTAssertTrue(privacy.removeAll)
        XCTAssertEqual(privacy.keepWhenRemovingAll, [.copyright])
        XCTAssertTrue(privacy.removeAuthor)
    }

    func testApplyNeverWeakensExistingRemoveAll() {
        var current = MetadataOptions(removeLocation: false)
        current.removeAll = true
        current.keepWhenRemovingAll = [.copyright, .author]
        var set = MetadataOptions(removeAll: true, removeLocation: false)
        set.keepWhenRemovingAll = [.copyright, .location]
        let merged = MetadataTemplates.apply(MetadataTemplate(name: "t", options: set), to: current)
        XCTAssertEqual(merged.keepWhenRemovingAll, [.copyright])
        let everything = MetadataTemplates.apply(MetadataTemplates.builtIns[2], to: current)
        XCTAssertTrue(everything.keepWhenRemovingAll.isEmpty)
    }

    func testBuiltInNamesAndIDsUnique() {
        let all = MetadataTemplates.builtIns
        XCTAssertEqual(Set(all.map { StoredFile.fold($0.name) }).count, all.count)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }
}
