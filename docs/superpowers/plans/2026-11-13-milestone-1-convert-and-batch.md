# Milestone 1: Convert + batch runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A usable first app: drop images/folders, pick an output format and quality, run a batch
conversion with progress and cancel, using any of the three output modes, never losing files.

**Architecture:** All logic lives in `ImageconverterCore` as small, testable units: formats →
loading → encoding → input collection → output planning → atomic file commit → batch runner. The
runner plans every destination serially up front (deterministic collision names), then decodes,
encodes and commits in parallel with bounded concurrency. The `Imageconverter` target is a thin
SwiftUI layer over an `@Observable` model, styled with the vendored Låda Glass.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftUI, macOS 14+, ImageIO, Core Graphics, UniformTypeIdentifiers, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-13-imageconverter-design.md` (read the "Output modes",
"Running a batch" and "Tech" sections before starting).

**Later milestones** get their own plans: 2 image steps + pipeline UI, 3 metadata + rename,
4 watermark, 5 presets + preview, 6 packaging/sandbox/About → 1.0.0. The sandbox folder-access
prompts belong to milestone 6 (`swift run` is not sandboxed), but nothing here may assume more
access than "the dropped items and the chosen output folder".

## Global Constraints

- macOS 14+, Swift tools 5.10, no third-party dependencies; Apple frameworks only.
- No network access of any kind.
- Writable formats: JPEG, PNG, HEIC, TIFF, plus GIF, BMP, JPEG 2000 when ImageIO reports it can write them.
- JPEG/HEIC quality default **0.82**; TIFF compression none or LZW.
- Pixel guard default **250 megapixels** (250_000_000 pixels); larger images are skipped with a reason.
- Animated/multi-page input: first frame only.
- Output modes: new folder (mirrors dropped folders' subfolders) · same folder, new name (default suffix **`_converted`**) · overwrite.
- Overwrite with a changed name/format writes the new file, then moves the original **to the Trash**; same name and format → atomic in-place replace.
- Never replace an unrelated existing file: append `_2`, `_3`, … (`name_2.jpg`).
- Writes go to a temp file in the destination folder, then are moved into place; no temp file survives an error or cancel.
- A failing file is skipped and reported; the run continues. Cancel keeps finished files.
- Overwrite warning: shown once when overwrite mode is *selected* in Settings, never at run time.
- UI: Låda Glass components/tokens only (`lgPanel`, `lgBackdrop`, `lgCompact`, `.buttonStyle(.lg(.primary))`, `LGChip`, `LGToastCenter`), dark default, keyboard accessible, English only.

## Review Focus

1. **Two inputs that map to the same output name** (`IMG_1.HEIC` and `IMG_1.png` → JPEG, same folder) → one gets `IMG_1.jpg`, the other `IMG_1_2.jpg`, deterministic in input order. *Test in Task 5.*
2. **EXIF-rotated photos** (orientation 6, typical iPhone portrait) → output is upright and its orientation tag is 1. *Tests in Tasks 2 and 3.*
3. **Transparent PNG → JPEG** → transparent areas become white, not black. *Test in Task 3.*
4. **Junk in a dropped folder** (`.DS_Store`, a `.txt`, a zero-byte `.jpg`, hidden files) → non-images are ignored silently; the broken `.jpg` is listed as a failure; the run finishes. *Tests in Tasks 4 and 7.*
5. **Cancel mid-run** → finished files stay, nothing half-written, no `.imageconverter-*.tmp` left behind. *Test in Task 7.*

---

### Task 1: Output formats and settings

**Files:**
- Create: `Sources/ImageconverterCore/OutputFormat.swift`
- Test: `Tests/ImageconverterCoreTests/OutputFormatTests.swift`
- Delete: `Tests/ImageconverterCoreTests/ImageconverterCoreTests.swift` and `greeting(for:)` in `Sources/ImageconverterCore/ImageconverterCore.swift` (delete the file; update `ContentView` to not call `greeting`, show a static subtitle instead)

**Interfaces:**
- Produces:
  - `public enum OutputFormat: String, Codable, CaseIterable, Sendable { case jpeg, png, heic, tiff, gif, bmp, jpeg2000 }`
  - `var utType: UTType` (`.jpeg`, `.png`, `.heic`, `.tiff`, `.gif`, `.bmp`, `UTType("public.jpeg-2000")!`)
  - `var fileExtensions: [String]` (first is preferred): jpeg `["jpg","jpeg"]`, png `["png"]`, heic `["heic"]`, tiff `["tif","tiff"]`, gif `["gif"]`, bmp `["bmp"]`, jpeg2000 `["jp2"]`
  - `var displayName: String` ("JPEG", "PNG", "HEIC", "TIFF", "GIF", "BMP", "JPEG 2000")
  - `var supportsQuality: Bool` (jpeg, heic, jpeg2000)
  - `static func available(writableTypeIdentifiers: [String] = systemWritableTypes()) -> [OutputFormat]` (allCases order, filtered)
  - `public static func systemWritableTypes() -> [String]` (from `CGImageDestinationCopyTypeIdentifiers()`)
  - `public enum TIFFCompression: String, Codable, Sendable { case none, lzw }`
  - `public struct OutputSettings: Codable, Equatable, Sendable { public var format: OutputFormat; public var quality: Double; public var tiffCompression: TIFFCompression; public init(format: OutputFormat = .jpeg, quality: Double = 0.82, tiffCompression: TIFFCompression = .lzw) }` (the public init is needed by the app target)

- [ ] **Step 1: Write the failing tests**

```swift
func testExtensionsAndTypes() {
    XCTAssertEqual(OutputFormat.jpeg.fileExtensions.first, "jpg")
    XCTAssertEqual(OutputFormat.tiff.fileExtensions, ["tif", "tiff"])
    XCTAssertEqual(OutputFormat.heic.utType, .heic)
}
func testAvailableFiltersAndKeepsOrder() {
    let fmts = OutputFormat.available(writableTypeIdentifiers: ["public.png", "public.jpeg", "com.example.nope"])
    XCTAssertEqual(fmts, [.jpeg, .png])
}
func testSystemWritesTheCoreFour() {
    let fmts = OutputFormat.available()
    for f in [OutputFormat.jpeg, .png, .heic, .tiff] { XCTAssertTrue(fmts.contains(f), "\(f)") }
}
func testSettingsDefaultsAndCodable() throws {
    let s = OutputSettings()
    XCTAssertEqual(s.quality, 0.82); XCTAssertEqual(s.format, .jpeg)
    let back = try JSONDecoder().decode(OutputSettings.self, from: JSONEncoder().encode(s))
    XCTAssertEqual(back, s)
}
```

- [ ] **Step 2: Run `swift test --filter OutputFormatTests`.** Expected: compile failure, `OutputFormat` not found.
- [ ] **Step 3: Implement** the interfaces above in `OutputFormat.swift`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass. Run `swift build`: the app target still compiles.
- [ ] **Step 5: Commit** `feat(core): output formats and settings`.

---

### Task 2: Loading images (orientation, first frame, pixel guard) + test helpers

**Files:**
- Create: `Sources/ImageconverterCore/ImageLoader.swift`, `Sources/ImageconverterCore/ConversionError.swift`
- Create: `Tests/ImageconverterCoreTests/Support/TestImages.swift`
- Test: `Tests/ImageconverterCoreTests/ImageLoaderTests.swift`

**Interfaces:**
- Produces:
  - `public enum ConversionError: Error, Equatable, Sendable { case unreadable, tooLarge(pixels: Int), encodeFailed, writeFailed(String) }` with `public var reason: String` (user-facing English: "Couldn't read this file as an image", "Image is too large (412 MP, limit 250 MP)", "Couldn't encode the image", "Couldn't write the file: …")
  - `public struct LoadedImage: @unchecked Sendable { public let image: CGImage; public let properties: [String: Any] }`. `properties` is the source's property dictionary with `kCGImagePropertyOrientation` set to 1 (and removed from the TIFF sub-dictionary's orientation too)
  - `public enum ImageLoader { public static func load(_ url: URL, maxPixels: Int = 250_000_000) throws -> LoadedImage }`
  - Test helpers (test target only): `TestImages.make(width:height:color:alpha:) -> CGImage` (solid RGBA), `TestImages.write(_ image: CGImage, to url: URL, type: UTType, properties: [String: Any] = [:])`, `TestImages.tempDir() -> URL` (unique dir under `FileManager.default.temporaryDirectory`, removed in `tearDown` by callers)

- [ ] **Step 1: Write the failing tests**

```swift
func testLoadsPNG() throws {
    let url = dir.appendingPathComponent("a.png")
    try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .png)
    let loaded = try ImageLoader.load(url)
    XCTAssertEqual(loaded.image.width, 40); XCTAssertEqual(loaded.image.height, 20)
}
func testAppliesExifOrientation() throws {   // Review Focus 2
    let url = dir.appendingPathComponent("rot.jpg")
    try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .jpeg,
                         properties: [kCGImagePropertyOrientation as String: 6])
    let loaded = try ImageLoader.load(url)
    XCTAssertEqual(loaded.image.width, 20); XCTAssertEqual(loaded.image.height, 40)
    XCTAssertEqual(loaded.properties[kCGImagePropertyOrientation as String] as? Int, 1)
}
func testRejectsOverPixelLimit() throws {
    let url = dir.appendingPathComponent("big.png")
    try TestImages.write(TestImages.make(width: 100, height: 100), to: url, type: .png)
    XCTAssertThrowsError(try ImageLoader.load(url, maxPixels: 9_999)) {
        XCTAssertEqual($0 as? ConversionError, .tooLarge(pixels: 10_000))
    }
}
func testCorruptAndEmptyFilesAreUnreadable() throws {
    let empty = dir.appendingPathComponent("empty.jpg"); try Data().write(to: empty)
    let junk = dir.appendingPathComponent("junk.png"); try Data("not an image".utf8).write(to: junk)
    for u in [empty, junk] {
        XCTAssertThrowsError(try ImageLoader.load(u)) { XCTAssertEqual($0 as? ConversionError, .unreadable) }
    }
}
```

- [ ] **Step 2: Run `swift test --filter ImageLoaderTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `ImageLoader.load`.** Approach: `CGImageSourceCreateWithURL` with `kCGImageSourceShouldCache: false`, then read index 0's properties. Compute pixels = width × height *before* decoding and throw `.tooLarge` if over the limit. Decode upright with `CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(w, h), kCGImageSourceShouldCacheImmediately: true])`. That applies the EXIF orientation at full size. A nil source, zero images or a nil image means `.unreadable`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): load images upright with a pixel guard`.

---

### Task 3: Encoding

**Files:**
- Create: `Sources/ImageconverterCore/ImageEncoder.swift`
- Test: `Tests/ImageconverterCoreTests/ImageEncoderTests.swift`

**Interfaces:**
- Consumes: `OutputFormat`, `OutputSettings` (Task 1); `ConversionError` (Task 2)
- Produces: `public enum ImageEncoder { public static func encode(_ image: CGImage, properties: [String: Any], settings: OutputSettings) throws -> Data }`

- [ ] **Step 1: Write the failing tests**

```swift
func testRoundTripsEveryAvailableFormat() throws {
    let img = TestImages.make(width: 32, height: 16)
    for f in OutputFormat.available() {
        let data = try ImageEncoder.encode(img, properties: [:], settings: .init(format: f))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, f.utType.identifier, "\(f)")
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(src, 0, nil)?.width, 32, "\(f)")
    }
}
func testJPEGQualityAffectsSize() throws {
    let img = TestImages.noise(width: 128, height: 128)   // add a noise helper to TestImages
    let low = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .jpeg, quality: 0.3))
    let high = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .jpeg, quality: 0.95))
    XCTAssertLessThan(low.count, high.count)
}
func testTransparentToJPEGIsWhite() throws {   // Review Focus 3
    let clear = TestImages.make(width: 8, height: 8, color: .clear, alpha: true)
    let data = try ImageEncoder.encode(clear, properties: [:], settings: .init(format: .jpeg))
    XCTAssertEqual(try TestImages.pixel(of: data, x: 4, y: 4).red, 255, accuracy: 3)  // add a pixel helper
}
func testWritesOrientationOneAndTIFFCompression() throws {   // Review Focus 2
    let data = try ImageEncoder.encode(TestImages.make(width: 8, height: 8),
        properties: [kCGImagePropertyOrientation as String: 6],
        settings: .init(format: .tiff, tiffCompression: .lzw))
    let props = try TestImages.properties(of: data)   // add helper
    XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int, 1)
    let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    XCTAssertEqual(tiff?[kCGImagePropertyTIFFCompression as String] as? Int, 5)
}
```

- [ ] **Step 2: Run `swift test --filter ImageEncoderTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `encode`.** Use `CGImageDestinationCreateWithData` with `settings.format.utType.identifier`. Pass the properties with orientation forced to 1, plus `kCGImageDestinationLossyCompressionQuality` when `supportsQuality`, plus TIFF compression 5 (LZW) or 1 (none) in the TIFF dictionary. For formats without alpha (jpeg, bmp) and an image with alpha, first draw onto an opaque white sRGB `CGContext`. A failed `finalize` throws `.encodeFailed`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): encode images to the output formats`.

---

### Task 4: Collecting inputs from drops

**Files:**
- Create: `Sources/ImageconverterCore/InputCollector.swift`
- Test: `Tests/ImageconverterCoreTests/InputCollectorTests.swift`

**Interfaces:**
- Produces:
  - `public struct InputItem: Hashable, Sendable { public let source: URL; public let relativeDirectory: String }`: `""` for a loose file; for a file found in a dropped folder `Trip`, the path from the dropped folder's *parent*, e.g. `"Trip"` or `"Trip/day2"`.
  - `public enum InputCollector { public static func collect(_ urls: [URL]) -> [InputItem] }`. Recursive; skips hidden files and folders and package contents; keeps files whose extension's `UTType` conforms to `.image` (so a corrupt `.jpg` is kept and fails later, while a `.txt` is dropped silently); dedupes by standardized path; sorted by `source.path` for deterministic order.

- [ ] **Step 1: Write the failing test** (Review Focus 4). Build `dir/Trip/{a.png, notes.txt, .DS_Store, .hidden.png, day2/b.jpg, day2/broken.jpg (0 bytes)}` and a loose `dir/c.heic` (valid, via TestImages). Call `collect([dir/Trip, dir/c.heic, dir/c.heic])` and assert the result equals:

```swift
[InputItem(source: trip/"a.png", relativeDirectory: "Trip"),
 InputItem(source: trip/"day2/b.jpg", relativeDirectory: "Trip/day2"),
 InputItem(source: trip/"day2/broken.jpg", relativeDirectory: "Trip/day2"),
 InputItem(source: dir/"c.heic", relativeDirectory: "")]   // sorted by path
```

- [ ] **Step 2: Run `swift test --filter InputCollectorTests`.** Expected: compile failure.
- [ ] **Step 3: Implement** with `FileManager.enumerator(at:includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): collect image inputs from dropped files and folders`.

---

### Task 5: Output planning (modes and collisions)

**Files:**
- Create: `Sources/ImageconverterCore/OutputPlanner.swift`
- Test: `Tests/ImageconverterCoreTests/OutputPlannerTests.swift`

**Interfaces:**
- Consumes: `InputItem` (Task 4), `OutputFormat` (Task 1)
- Produces:
  - `public enum OutputMode: Codable, Equatable, Sendable { case newFolder(URL), sameFolder(suffix: String), overwrite }` with `public var kind: OutputModeKind`
  - `public enum OutputModeKind: String, Codable, CaseIterable, Sendable { case newFolder, sameFolder, overwrite }`
  - `public func needsOverwriteWarning(from old: OutputModeKind, to new: OutputModeKind) -> Bool` (true only when `new` is `.overwrite` and `old` isn't)
  - `public struct PlannedOutput` gets a public memberwise `init(item:destination:replacesSource:trashesSource:)`
  - `public struct PlannedOutput: Equatable, Sendable { public let item: InputItem; public let destination: URL; public let replacesSource: Bool; public let trashesSource: Bool }`
  - `public enum OutputPlanner { public static func plan(_ items: [InputItem], format: OutputFormat, mode: OutputMode, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [PlannedOutput] }`

Rules (in input order; a set of already-claimed destinations is kept during planning):
- newFolder(root): `root/relativeDirectory/<name>.<ext>`
- sameFolder(suffix): `sourceDir/<name><suffix>.<ext>`
- overwrite: if the source's extension (case-insensitive) is in `format.fileExtensions`, the destination is the source URL itself with `replacesSource = true`. Otherwise `sourceDir/<name>.<ext>` with `trashesSource = true`.
- `<ext>` = `format.fileExtensions[0]`. Collision: if the candidate is claimed, or exists and isn't the item's own source, try `<name>_2`, `_3`, …

- [ ] **Step 1: Write the failing tests**

```swift
func testNewFolderMirrorsSubfolders()  // Trip/day2/b.jpg → root/Trip/day2/b.jpg; loose c.heic → root/c.jpg
func testSameFolderUsesSuffix()        // a.png, suffix "_converted", jpeg → sourceDir/a_converted.jpg
func testOverwriteSameFormatReplacesInPlace()   // A.JPG + jpeg → destination == source, replacesSource
func testOverwriteFormatChangeTrashes()          // a.heic + jpeg → a.jpg, trashesSource, !replacesSource
func testSameNameInputsGetNumbered() {   // Review Focus 1
    let plans = OutputPlanner.plan([item("IMG_1.HEIC"), item("IMG_1.png")], format: .jpeg,
                                   mode: .sameFolder(suffix: ""), fileExists: { _ in false })
    XCTAssertEqual(plans.map(\.destination.lastPathComponent), ["IMG_1.jpg", "IMG_1_2.jpg"])
}
func testNeverReplacesUnrelatedExistingFile()   // overwrite a.png→jpeg while a.jpg exists → a_2.jpg
func testOverwriteWarningOnlyWhenSwitchingTo()  // (newFolder→overwrite) true; (overwrite→overwrite) false; (overwrite→sameFolder) false
```

Write each with explicit `XCTAssertEqual` on `destination.path`, `replacesSource` and `trashesSource`, using a fake `fileExists`.

- [ ] **Step 2: Run `swift test --filter OutputPlannerTests`.** Expected: compile failure.
- [ ] **Step 3: Implement** per the rules above.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): plan output paths for the three output modes`.

---

### Task 6: Atomic commit to disk

**Files:**
- Create: `Sources/ImageconverterCore/FileCommitter.swift`
- Test: `Tests/ImageconverterCoreTests/FileCommitterTests.swift`

**Interfaces:**
- Consumes: `PlannedOutput` (Task 5), `ConversionError` (Task 2)
- Produces:
  - `public typealias Trasher = @Sendable (URL) throws -> Void`
  - `public let systemTrash: Trasher` (`FileManager.default.trashItem(at:resultingItemURL:)`)
  - `public enum FileCommitter { public static let tempPrefix = ".imageconverter-"; public static func commit(_ data: Data, for plan: PlannedOutput, trash: Trasher = systemTrash) throws }`

Behaviour: create the destination's folder (with intermediates); write `data` to `<destDir>/.imageconverter-<UUID>.tmp`; if `replacesSource`, `FileManager.replaceItemAt(destination, withItemAt: tmp)`; otherwise `moveItem(tmp → destination)`, which fails if something appeared there meanwhile. Then, if `trashesSource`, call `trash(source)`. On any error, remove the temp file and throw `.writeFailed(<underlying localizedDescription>)`.

- [ ] **Step 1: Write the failing tests**

```swift
func testWritesNewFileAndCreatesFolders()       // dest in missing subfolder → file exists with data, no temp files in dir
func testReplacesInPlace()                       // source has "old", commit "new" with replacesSource → contents "new"
func testTrashesSourceOnFormatChange()           // trash closure records the URL == source; dest written
func testExistingDestinationIsNotClobbered()     // dest already has "keep" → throws .writeFailed, still "keep", no temp left
func testFailureLeavesNoTempFile()               // dest dir made read-only (0o555) → throws, dir has no ".imageconverter-" files
```

Helper: `func tempFiles(in dir: URL) -> [String]` returns the names with `FileCommitter.tempPrefix`. Assert it's empty in every test.

- [ ] **Step 2: Run `swift test --filter FileCommitterTests`.** Expected: compile failure.
- [ ] **Step 3: Implement** as described.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): commit outputs atomically and trash replaced originals`.

---

### Task 7: Batch runner (parallel, progress, skip-on-error, cancel)

**Files:**
- Create: `Sources/ImageconverterCore/BatchRunner.swift`
- Test: `Tests/ImageconverterCoreTests/BatchRunnerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6
- Produces:
  - `public struct BatchProgress: Equatable, Sendable { public let completed: Int; public let failed: Int; public let total: Int }` (completed counts successes and failures)
  - `public struct BatchFailure: Equatable, Sendable { public let source: URL; public let reason: String }`
  - `public struct BatchReport: Equatable, Sendable { public var written: [URL]; public var failures: [BatchFailure]; public var cancelled: Bool }`
  - `public enum BatchRunner { public static func run(_ items: [InputItem], output: OutputSettings, mode: OutputMode, maxPixels: Int = 250_000_000, concurrency: Int = ProcessInfo.processInfo.activeProcessorCount, trash: @escaping Trasher = systemTrash, progress: @escaping @Sendable (BatchProgress) -> Void = { _ in }) async -> BatchReport }`

Approach: `OutputPlanner.plan` first, serially. Then a `withTaskGroup` sliding window, keeping at most `concurrency` children in flight. Each child runs load → encode → commit inside `autoreleasepool` and returns success or failure (`ConversionError.reason`, or `localizedDescription` for other errors). Check `Task.isCancelled` before starting each new item and set `cancelled = true` if so. Items in flight finish their atomic commit. Report `written` and `failures` in input order.

- [ ] **Step 1: Write the failing tests**

```swift
func testConvertsAndSkipsBrokenFiles() async throws {   // Review Focus 4
    // 5 valid PNGs + 1 zero-byte "broken.jpg" in src; mode .newFolder(out), JPEG
    let report = await BatchRunner.run(items, output: .init(format: .jpeg), mode: .newFolder(out), progress: { log.append($0) })
    XCTAssertEqual(report.written.count, 5)
    XCTAssertEqual(report.failures.map(\.source.lastPathComponent), ["broken.jpg"])
    XCTAssertEqual(report.failures.first?.reason, ConversionError.unreadable.reason)
    XCTAssertEqual(log.last, BatchProgress(completed: 6, failed: 1, total: 6))
    for url in report.written { XCTAssertNoThrow(try ImageLoader.load(url)) }
}
func testCancelKeepsFinishedFilesAndLeavesNoTemps() async throws {   // Review Focus 5
    // 40 images of 1500×1500 noise, concurrency 2; cancel the task from the first progress callback
    XCTAssertTrue(report.cancelled)
    XCTAssertLessThan(report.written.count, 40)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasPrefix(".imageconverter-") }, [])
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)).count, report.written.count)
}
func testOverwriteFormatChangeTrashesOriginals() async   // a.heic → jpeg, overwrite, fake trash records [a.heic]; a.jpg exists
```

(`log` is a small lock-protected array helper in `Support/`.)

- [ ] **Step 2: Run `swift test --filter BatchRunnerTests`.** Expected: compile failure.
- [ ] **Step 3: Implement** as described.
- [ ] **Step 4: Run `swift test`.** Expected: all pass. Run it twice to catch flakiness in the cancel test.
- [ ] **Step 5: Commit** `feat(core): batch runner with progress, skip-on-error and cancel`.

---

### Task 8: Minimal app UI, Settings and docs

**Files:**
- Create: `Sources/Imageconverter/AppModel.swift`, `Sources/Imageconverter/AppSettings.swift`, `Sources/Imageconverter/SidebarView.swift`, `Sources/Imageconverter/SettingsView.swift`
- Modify: `Sources/Imageconverter/ImageconverterApp.swift` (replace the starter `ContentView`; add a `Settings` scene and commands)
- Modify: `README.md` ("How to: convert a batch", Configuration table: mark which settings work now), `CHANGELOG.md` (Unreleased), `CLAUDE.md` (Layout: list the new Core files)

**Interfaces:**
- Consumes: everything from Core
- Produces (app target only):
  - `@MainActor @Observable final class AppSettings`, persisted in `UserDefaults`: `modeKind: OutputModeKind` (key `"outputModeKind"`, default `.newFolder`), `outputFolder: URL?` (key `"outputFolder"`, default nil), `sameFolderSuffix: String` (key `"sameFolderSuffix"`, default `"_converted"`), and computed `outputMode: OutputMode?` (nil only when the kind is new folder and no folder has been chosen yet).
  - `@MainActor @Observable final class AppModel`: `items: [InputItem]`, `output: OutputSettings`, `progress: BatchProgress?`, `lastReport: BatchReport?`, `isRunning: Bool`, `func add(_ urls: [URL])` (uses `InputCollector`, appends, dedupes), `func clear()`, `func run(settings: AppSettings)`, `func cancel()`

Behaviour:
- **Sidebar** (`lgPanel`, `lgBackdrop`, `lgCompact`): a drop zone (`.dropDestination(for: URL.self)`) labelled "Drop images or folders here" with "Add…" (⌘O, `NSOpenPanel` that allows files + folders + multiple selection). Below it, `LGChip("\(n) images")` and a "Clear" button. Then an "Output" section with a format `Picker` from `OutputFormat.available()`, a quality slider (only when `supportsQuality`, shown as a percentage), and a TIFF compression picker for TIFF. Then a one-line summary of the output mode with a "Change…" button that opens Settings. Last, **Run on N images** (`.buttonStyle(.lg(.primary))`, ⌘R, disabled when empty or running).
- **Running:** `ProgressView(value:total:)` with "57 / 124", and Cancel (⌘.). When done, a toast via `LGToastCenter`: "Converted 122 images" (`.ok`) or "Converted 122, 2 skipped" (`.bad`), plus an expandable list of failures (file name and reason) in the sidebar until the next run.
- **New folder mode with no folder yet:** Run first opens an `NSOpenPanel` (choose a folder, "Choose output folder"), stores it, then runs.
- **Settings** (⌘,): a segmented control for the three modes, a folder chooser for "New folder", and a suffix field for "Same folder". Selecting overwrite when `needsOverwriteWarning(from:to:)` is true shows a `.confirmationDialog`: "Overwrite originals?" / "Converted images will replace the originals. When the format or name changes, the original is moved to the Trash. You won't be asked again when running." with the buttons **Use overwrite** and **Cancel**. Cancel reverts the selection. No warning at run time.
- Every control has an accessibility label; everything is reachable with Tab.

- [ ] **Step 1: Implement** the files above. The UI isn't unit-tested; all logic it needs is already tested in Core.
- [ ] **Step 2: Verify the build and lint.** Run `swift build && swift test && swiftlint --strict` (skip swiftlint if not installed, and say so). Expected: build OK, all tests pass, 0 lint violations.
- [ ] **Step 3: Verify manually with `swift run`.** Make sample input with `mkdir -p /tmp/ic/in/sub && sips -s format heic /System/Library/Desktop\ Pictures/*.heic` (or any images to hand) into `/tmp/ic/in` and `/tmp/ic/in/sub`, plus `touch /tmp/ic/in/broken.jpg`. Check:
  (a) drop `in/` → count shown; JPEG 82 % → new folder `/tmp/ic/out` → `out/in/…` and `out/in/sub/…` exist and the failure list shows `broken.jpg`;
  (b) same-folder mode → `*_converted.jpg` next to the originals;
  (c) switching to overwrite shows the dialog once, and Cancel reverts it; with it on, PNG → JPEG puts the PNGs in the Trash and no dialog appears at run time;
  (d) Cancel during a large run leaves no `.imageconverter-*` files (`ls -a`).
  Take a screenshot for the README if `claude-shots` works.
- [ ] **Step 4: Update the docs.** README how-to ("Convert a batch"); the Configuration table notes that the settings now work; CHANGELOG Unreleased: "Batch conversion: drop images or folders, choose JPEG/PNG/HEIC/TIFF (and GIF/BMP/JPEG 2000 where available), quality, three output modes, progress and cancel; unreadable files are skipped and listed"; CLAUDE.md Layout lists the Core files. Don't bump VERSION (bump only on push).
- [ ] **Step 5: Commit** `feat(app): minimal batch conversion UI with output settings`, staging only the files from this task.
