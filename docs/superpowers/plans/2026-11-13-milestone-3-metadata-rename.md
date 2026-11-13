# Milestone 3: Metadata + rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two file steps, Metadata (strip location, camera details or everything; set
artist, copyright and description) and Rename (a token pattern such as
`{date:yyyy-MM-dd}_{camera}_{counter:000}`). Both run in batches and are edited in the sidebar's
"Always last" section.

**Architecture:**
- `Pipeline` gains two optional file steps, `metadata` and `rename`. Decoding is lenient, so
  pipelines saved by milestone 2 still load.
- Metadata is a pure transform on the ImageIO property dictionary, applied just before encoding.
- Rename is a small template language (parse → render → sanitise). It renders from a header-only
  read of each file (EXIF date, make, model, lens, ISO), plus the output size predicted with
  `Geometry` (no decoding).
- Names are rendered serially at planning time, so counters and collision numbering stay
  deterministic. `OutputPlanner` takes the rendered base names.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftUI, macOS 14+, ImageIO, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-13-imageconverter-design.md`. Read "File steps",
"Rename tokens" and "Output modes".

## Global Constraints

- Metadata choices: keep · remove GPS/location · remove camera/device details · remove all. Set or replace: artist, copyright, description. Removal happens before setting.
- **Anti-goal:** metadata the user asked to strip must not end up in the output file in any form (checked on the written bytes).
- The color profile is never "metadata" here. Stripping never changes how the image looks.
- Rename tokens (exact): `{name}` `{ext}` `{date}` `{date:<format>}` `{time}` `{time:<format>}` `{camera}` (model) `{make}` `{lens}` `{iso}` `{width}` `{height}` (output pixel size) `{format}` `{folder}` (source folder name) `{counter}` `{counter:000}` (zero padding = number of 0s); the counter has a start number (default 1). `{date}` defaults to `yyyy-MM-dd` and `{time}` to `HHmmss`.
- Capture date = EXIF DateTimeOriginal, falling back to the file's creation date. EXIF times have no time zone: parse and format them in a fixed GMT time zone, so the day never shifts.
- Metadata is untrusted. Token values and the final name are sanitised:
  - no `/`, `:` or control characters;
  - no leading dots;
  - length capped at 200 characters;
  - empty values become empty strings;
  - runs of `_`/`-`/spaces left by empty tokens collapse to one, and are trimmed at the ends;
  - an empty final name falls back to the original name.
- Same-folder mode uses the rename pattern when Rename is on (no suffix), otherwise `{name}` + the suffix. Overwrite mode with a rename that changes the name moves the original to the Trash (existing planner behaviour).
- Collisions from identical rendered names get `_2`, `_3`, … (existing planner behaviour). The counter follows input order.
- Pipelines saved by milestone 2 must still load. Missing new fields take their defaults.
- UI: Låda Glass only, keyboard accessible, English only, accessibility labels on every control.

## Review Focus

1. **GPS/camera data leaking after stripping**, including in maker notes and IPTC → the written bytes don't contain it. *Test in Task 4.*
2. **Hostile or empty token values**: a camera model `../../x:y`, no camera at all, a pattern that renders to nothing → a safe name and the original-name fallback. *Tests in Task 3.*
3. **A pattern without a counter over many files** → `_2`, `_3`, …, nothing overwritten, nothing lost. *Test in Task 4.*
4. **A pipeline saved by milestone 2** → loads with its steps intact. *Test in Task 1.*
5. **Missing or malformed EXIF dates, and time zones** → file-date fallback, no crash, and the day is not shifted. *Tests in Task 3.*

---

### Task 1: Model: file steps, header reading, lenient decoding

**Files:**
- Create: `Sources/ImageconverterCore/FileSteps.swift`
- Modify: `Sources/ImageconverterCore/Pipeline.swift` (new fields, custom `init(from:)`), `Sources/ImageconverterCore/ImageLoader.swift` (header), `Sources/ImageconverterCore/StepSummary.swift`
- Test: `Tests/ImageconverterCoreTests/FileStepsModelTests.swift`

**Interfaces (all public, Codable/Equatable/Sendable, public inits):**
- `struct MetadataOptions { var isEnabled = false; var removeAll = false; var removeLocation = true; var removeCamera = false; var artist: String? = nil; var copyright: String? = nil; var description: String? = nil }`. A nil field is left as is; a non-nil field is set (an empty string clears it).
- `struct RenameOptions { var isEnabled = false; var pattern = "{name}"; var counterStart = 1 }`
- `Pipeline` gains `var metadata = MetadataOptions()` and `var rename = RenameOptions()`. `init(from:)` uses `decodeIfPresent` with defaults for `schemaVersion`, `steps`, `output`, `metadata` and `rename`. `schemaVersion` stays 1.
- `struct ImageHeader: Sendable { let width: Int; let height: Int; let properties: [String: Any] }` (`@unchecked Sendable`), and `ImageLoader.header(of url: URL) -> ImageHeader?` (header only, no decode; nil if unreadable). `pixelSize(of:)` reuses it.
- Summaries:
  - `MetadataOptions.summary`: `keep` / `strip all` / `strip GPS` / `strip camera` / `strip GPS + camera`, plus ` · set artist, copyright` listing the fields that are set (`artist`, `copyright`, `description`).
  - `RenameOptions.summary`: the pattern itself.

- [ ] **Step 1: Write the failing tests.**
  - `testMilestone2PipelineStillDecodes`: a JSON literal with only `schemaVersion`, `steps` (one resize step) and `output` decodes, keeps the step, and gets default metadata and rename.
  - `testRoundTripWithFileSteps`.
  - `testMetadataSummaries`: one assertion per variant above.
  - `testHeaderReadsSizeAndExif`: write a JPEG with EXIF DateTimeOriginal `"2024:06:01 23:30:00"` and TIFF Model `"iPhone 15 Pro"`; `header` returns 40×20 and those properties.
  - `testHeaderNilForJunk`.
- [ ] **Step 2: Run `swift test --filter FileStepsModelTests`.** Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): metadata and rename options, header reading`.

---

### Task 2: Metadata transform

**Files:**
- Create: `Sources/ImageconverterCore/MetadataOps.swift`
- Modify: `Sources/ImageconverterCore/ImageEncoder.swift` (also drop stale color tags)
- Test: `Tests/ImageconverterCoreTests/MetadataOpsTests.swift`

**Interfaces:**
- `public enum MetadataOps { public static func apply(_ options: MetadataOptions, to properties: [String: Any]) -> [String: Any] }`. When `isEnabled` is false it returns the input unchanged. Otherwise, in this order:
  - **removeAll:** keep nothing, an empty dictionary. Orientation and color are handled by the encoder and the image.
  - **removeLocation:** remove the `{GPS}` dictionary. From `{IPTC}` remove City, Sub-location, Province/State, Country/PrimaryLocationName and CountryCode.
  - **removeCamera:**
    - from `{TIFF}`, remove Make, Model, Software, HostComputer;
    - from `{Exif}`, remove LensMake, LensModel, LensSpecification, BodySerialNumber, LensSerialNumber, CameraOwnerName;
    - remove `{ExifAux}` and every maker dictionary (`{MakerCanon}`, `{MakerNikon}`, `{MakerMinolta}`, `{MakerFuji}`, `{MakerOlympus}`, `{MakerPentax}`, `{MakerApple}`, and any key that starts with `{Maker`).
  - **set:**
    - artist → TIFF Artist + IPTC Byline (array)
    - copyright → TIFF Copyright + IPTC CopyrightNotice
    - description → TIFF ImageDescription + IPTC Caption/Abstract
    - Create the sub-dictionaries if missing.
- `ImageEncoder` sanitising also drops `{Exif}.ColorSpace` and the `{PNG}` Gamma, Chromaticities and sRGBIntent keys. They are stale after color steps; the ICC profile comes from the image.

- [ ] **Step 1: Write the failing tests.** Pure dictionary tests, with a fixture holding GPS, IPTC City, TIFF Make/Model, Exif LensModel, `{MakerApple}` and Artist.
  - `testDisabledIsIdentity`
  - `testRemoveLocation`: GPS and IPTC City gone, Make kept.
  - `testRemoveCamera`: Make, Model, LensModel and `{MakerApple}` gone, GPS kept.
  - `testRemoveAllThenSet`: the result contains only TIFF Artist and IPTC Byline.
  - `testSetDoesNotTouchOthers`
  - `testEncoderDropsStaleColorTags`: an Exif ColorSpace of 65535 in the input is not in the re-read output.
- [ ] **Step 2: Run the focused tests.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): metadata strip and set`.

---

### Task 3: Rename templates

**Files:**
- Create: `Sources/ImageconverterCore/RenameTemplate.swift`
- Test: `Tests/ImageconverterCoreTests/RenameTemplateTests.swift`

**Interfaces:**
- `public struct RenameContext: Sendable { name, ext, format, folder: String; date: Date?; make, model, lens: String?; iso: Int?; width, height: Int; counter: Int }` with a public memberwise init.
  - `public static func make(source: URL, header: ImageHeader?, outputSize: (Int, Int), format: OutputFormat, counter: Int, fileCreationDate: Date?) -> RenameContext` reads EXIF/TIFF values. `date` is DateTimeOriginal parsed as `yyyy:MM:dd HH:mm:ss` in GMT; otherwise `fileCreationDate` re-expressed in GMT with the same wall-clock values as the user's current time zone, so the formatted day matches what Finder shows.
- `public struct RenameTemplate: Equatable, Sendable`:
  - `init(_ pattern: String)` parses literals and `{token}` / `{token:arg}`
  - `var unknownTokens: [String]` lists names outside the token list; they render literally, braces included.
  - `func render(_ context: RenameContext) -> String` returns the **base name without extension**, sanitised per Global Constraints and falling back to `context.name` when empty.
- Formatting:
  - Dates use `DateFormatter` with `en_US_POSIX` and GMT.
  - `{counter:000}` → zero-padded to 3 digits; a bare `{counter}` has no padding.
  - `{iso}` → the integer (the first value of ISOSpeedRatings).
  - `{ext}` → the output extension; `{format}` → `OutputFormat.displayName`.

- [ ] **Step 1: Write the failing tests** with explicit strings:

```swift
func testExamplePattern()      // "{date:yyyy-MM-dd}_{camera}_{counter:000}", date 2024-06-01 23:30 GMT, model "iPhone 15 Pro", counter 7 → "2024-06-01_iPhone 15 Pro_007"
func testDayNotShiftedByTimeZone()   // EXIF "2024:06:01 23:30:00", run with TimeZone.current forced to UTC+10 via NSTimeZone.default in setUp/tearDown → "2024-06-01"
func testFallbackToFileDate()        // no EXIF date → formats fileCreationDate
func testMalformedExifDate()         // "garbage" → falls back, no crash
func testHostileValuesSanitised() {  // Review Focus 2
    // model "../../x:y", pattern "{camera}": result contains no "/" or ":" and no control chars,
    // does not start with "." or a separator, and is non-empty. "/" and ":" become "-".
}
func testEmptyTokensCollapseSeparators()   // "{camera}_{name}" with no camera → "IMG_1" (not "_IMG_1")
func testEmptyResultFallsBackToName()      // "{lens}" with no lens → original name
func testUnknownTokenRendersLiterally()    // "{foo}_{name}" → unknownTokens ["foo"], "{foo}_IMG_1"
func testAllTokens()                       // one assertion per token incl. width/height/format/folder/ext/iso/make/time
func testLengthCapped()                    // 500-char literal → 200 chars
```

- [ ] **Step 2: Run `swift test --filter RenameTemplateTests`.** Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): rename templates with tokens and sanitising`.

---

### Task 4: Wire metadata and rename into planning and the batch

**Files:**
- Modify: `Sources/ImageconverterCore/OutputPlanner.swift`, `Sources/ImageconverterCore/BatchRunner.swift`, `Sources/ImageconverterCore/Pipeline.swift` (add `outputSize`), existing planner/runner tests
- Test: `Tests/ImageconverterCoreTests/FileStepsBatchTests.swift`

**Interfaces:**
- `extension Pipeline { public func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) }` gives the size after the enabled image steps, from `Geometry`. It shares the walk with `peakPixels`; don't duplicate the step walk.
- `OutputPlanner.plan(_:format:mode:baseNames: [String]? = nil, fileExists:)`.
  - When `baseNames` is given it replaces `<name>` per item, and **same-folder mode then uses no suffix**.
  - When nil, behaviour is unchanged.
- `BatchRunner.run`, during planning (serial, input order): if `pipeline.rename.isEnabled`, then for each item, with `counter = counterStart + index`:
  - read the header;
  - compute `outputSize`;
  - build the context;
  - render the base names.
- In `convert`: `properties = MetadataOps.apply(pipeline.metadata, to: loaded.properties)` before encoding.

- [ ] **Step 1: Write the failing tests.**
  - `testGPSNeverLeaks` (Review Focus 1)
    - Source JPEG with a GPS dictionary, including GPSAreaInformation `"SECRETPLACE-42"`, and IPTC City `"SECRETCITY"`.
    - Metadata removeLocation, output JPEG.
    - Re-read: no `{GPS}`. **The raw output bytes do not contain** `SECRETPLACE-42` or `SECRETCITY`.
    - Repeat with removeAll and output HEIC.
  - `testCameraNeverLeaks`: the Model `"SECRETCAM"` is not in the output bytes after removeCamera.
  - `testRenameWithCounter`: 3 files, pattern `"trip_{counter:00}"`, start 1 → `trip_01.jpg`, `trip_02.jpg`, `trip_03.jpg` in input order.
  - `testRenameCollisions` (Review Focus 3): 4 files, pattern `"same"` → `same.jpg`, `same_2.jpg`, `same_3.jpg`, `same_4.jpg`; 4 files exist.
  - `testWidthTokenMatchesOutput`: resize maxWidth 100 on 400×200, pattern `"{width}x{height}"` → `100x50.jpg`, and the file really is 100×50.
  - `testSameFolderWithRenameHasNoSuffix`
  - `testOverwriteRenameTrashesOriginal`: fake trash.
- [ ] **Step 2: Run the focused tests.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test` twice.** Expected: all pass, and the cancel test is stable.
- [ ] **Step 5: Commit** `feat(core): apply metadata and rename in batches`.

---

### Task 5: Metadata and Rename editors, docs

**Files:**
- Create: `Sources/Imageconverter/FileStepEditors.swift`
- Modify: `Sources/Imageconverter/PipelineSection.swift` ("Always last" gains Metadata and Rename rows above Output), `Sources/Imageconverter/AppModel.swift` (live example), `README.md`, `CHANGELOG.md`, `CLAUDE.md`

**Behaviour:**
- The Metadata and Rename rows look like image-step rows, with a toggle, title, summary and accordion, but have no drag handle and no ⋯ menu.
- **Metadata editor:**
  - "Remove all metadata" toggle. When it is on, the next two are disabled and shown as included.
  - "Remove location (GPS)" toggle and "Remove camera details" toggle.
  - Then three "Set …" rows (Artist, Copyright, Description), each a toggle plus a text field. Toggle off means nil.
  - Caption (muted): "The color profile is always kept."
- **Rename editor:**
  - The pattern text field (monospaced).
  - An "Insert token" `Menu` that appends a token at the end. The entries are the token list, with `{date:yyyy-MM-dd}`, `{time:HHmmss}` and `{counter:000}` as the formatted examples.
  - "Counter starts at" number field (≥ 0).
  - A warning line (Låda Glass warn colour) when `unknownTokens` isn't empty: "Unknown token: {foo}".
  - **Example** line: `Example: <rendered>.<ext>`. It renders with the first image in the batch (header read off the main actor, then cached until the items or the pipeline change). With no images it uses a built-in sample context: name `IMG_0001`, date 2026-11-13 14:05:09, make Apple, model iPhone 15 Pro, lens `iPhone 15 Pro back camera 6.765mm f/1.78`, ISO 80, 4032×3024 before steps. The selected-image example arrives with the preview in milestone 5 **(Claude's call)**.
- The output mode summary for same-folder mode says "Same folder, renamed" when Rename is on.
- **Docs:**
  - README: Features marks metadata and rename available; a how-to for "Strip location before sharing" and "Rename by date and camera"; and a token table (each token, its meaning and an example).
  - CHANGELOG Unreleased: "Metadata step (remove location, camera details or everything; set artist, copyright and description) and Rename step with tokens ({date}, {camera}, {counter:000}, …) and a live example."
  - CLAUDE.md layout: list the new files.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** Run `swift build && swift test && swiftlint --strict`. Expected: 0 warnings, all pass, 0 violations.
- [ ] **Step 3: Smoke-launch.** Run `swift run` in the background for 5 s, then kill it and make sure no process or shell is left. In the report, list the interactive checks *not* done.
- [ ] **Step 4: Commit** `feat(app): metadata and rename editors`, staging only this task's files.
