# Milestone 5: Presets + preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Saved, named presets (with a few built-ins) and the collapsible before/after preview with a
filmstrip of the batch, as designed in layout B.

**Architecture:**
- **Presets:** one JSON file per preset in Application Support, named by UUID. They are validated on
  load and written atomically through a `PresetStore` in Core, with an injectable directory.
  Built-ins live in code and are read-only.
- **Preview:** the pipeline runs on the **full-resolution** selected image, off the main actor,
  debounced and cancellable. A downscaled result shows the before and after images, the old → new
  name and the pixel sizes. Rendering at full size keeps every pixel-valued option (resize to
  1600 px, 20 px padding) exact.
- **Filmstrip:** small thumbnails, loaded lazily off the main actor. The selected item drives the
  preview and the rename example.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftUI, macOS 14+, ImageIO, Core Graphics, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-13-imageconverter-design.md`, "Presets" and "Main window (layout B)".

## Global Constraints

- **Preset files:**
  - **Location:** `~/Library/Application Support/imageconverter/presets/<UUID>.json`, one file per preset.
  - **Format:** `{"schemaVersion": 1, "id", "name", "pipeline"}`.
  - **Writes:** atomic.
  - **Loading:** size limit 1 MB; files whose name isn't a UUID are ignored; an invalid file is skipped and reported, never crashing. `Pipeline` decoding is already lenient.
  - **Versions:** a preset with `schemaVersion` > 1 is rejected with a message, never silently rewritten.
- The **output mode is not part of a preset** (it stays a global setting). Presets carry the pipeline only: steps, output format/quality, metadata, rename.
- **Preset names:** 1–80 characters after trimming, unique ignoring case (built-ins included), and control characters removed. Names never become file names; the UUID does.
- **Built-in presets** (read-only, can't be deleted, renamed or overwritten; "Save" on a built-in means "Save as"):
  - **Web export:** resize fit 2048 × 2048, color sRGB, metadata strip location, JPEG 82 %.
  - **Instagram 4:5:** resize exact 1080 × 1350 fill & crop, sRGB, metadata strip location, JPEG 85 %.
  - **Archive TIFF:** no image steps, metadata off, TIFF LZW.
- **Switching presets with unsaved changes** asks: "Discard changes to <name>?" with **Discard** and **Cancel**.
- **The preview never blocks the UI:**
  - render off the main actor;
  - debounce 300 ms after edits;
  - cancel stale renders and discard their results;
  - respect the 250 MP pixel guard;
  - show a failure reason (e.g. "Couldn't read the watermark image") instead of an image when a render fails.
- **The preview shows:** before | after (scaled to fit), `old name → new name`, `W × H → W × H`, and a filmstrip of the batch. Both the preview and the pipeline section collapse **(Johan)**. The collapsed state persists.
- UI: Låda Glass only, keyboard accessible (the filmstrip uses arrow keys), English only, accessibility labels on every control.

## Review Focus

1. **Tampered preset files:** huge, truncated, wrong types, non-UUID names, future schema, unknown step kinds → skipped or loaded leniently with a reason, and never a crash. *Tests in Task 1.*
2. **Switching presets with unsaved edits** → confirmation, with no silent loss. Built-ins can't be overwritten. *Tests in Task 2 (model logic in Core).*
3. **Previewing a huge or slow image while editing quickly** → the UI stays responsive, the latest edit wins, and no stale render overwrites a newer one. *Tests in Task 3.*
4. **A preview whose pipeline needs a watermark image** → it uses the batch's asset loader. A missing logo shows the reason. *Test in Task 3.*
5. **An empty batch** → the preview shows a hint, not an error. *Task 4.*

---

### Task 1: PresetStore (Core)

**Files:**
- Create: `Sources/ImageconverterCore/Presets.swift`
- Test: `Tests/ImageconverterCoreTests/PresetStoreTests.swift`

**Interfaces:**
- `public struct Preset: Codable, Equatable, Sendable, Identifiable { public var id: UUID; public var name: String; public var pipeline: Pipeline; public var isBuiltIn: Bool }`. `isBuiltIn` is not encoded.
- `public enum PresetError: Error, Equatable { case invalidName(String), duplicateName, builtInReadOnly, unsupportedVersion(Int), tooLarge, unreadable }` with an English `reason`.
- `public struct PresetLoadResult { public var presets: [Preset]; public var skipped: [(file: String, reason: String)] }`
- `public final class PresetStore: @unchecked Sendable` (serial internal queue or lock), `init(directory: URL)`:
  - `static var defaultDirectory: URL`
  - `static let builtIns: [Preset]`, with fixed UUIDs
  - `func loadAll() -> PresetLoadResult` returns the built-ins first, then user presets sorted by name, case-insensitive
  - `func save(_ preset: Preset) throws` (validates the name, rejects built-ins, writes atomically)
  - `func rename(id: UUID, to: String) throws`
  - `func delete(id: UUID) throws` (built-in → error; deleting a missing file is not an error)
  - `static func validatedName(_ raw: String, existing: [Preset], excluding: UUID?) throws -> String`

- [ ] **Step 1: Write the failing tests.**
  - Round trip: save, load, and the preset is equal.
  - Built-ins first, with the exact pipelines above.
  - Built-in save, rename and delete each throw `builtInReadOnly`.
  - Name rules: an empty name, an 81-character name, `"web export"` (a duplicate of a built-in) and a control character → stripped or error.
  - Tampered files, each skipped with a reason while the other presets still load (Review Focus 1):
    - a 2 MB file;
    - truncated JSON;
    - `"pipeline": 5`;
    - a non-UUID file name (ignored);
    - `schemaVersion` 2.
  - Unknown step kind: the preset loads with that step dropped.
  - Delete removes the file. Rename keeps the id.
- [ ] **Step 2: Run the tests.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): preset store with built-ins and validation`.

---

### Task 2: Preset session logic (Core) and preset UI

**Files:**
- Create: `Sources/ImageconverterCore/PresetSession.swift` (pure state machine), `Sources/Imageconverter/PresetBar.swift`
- Modify: `Sources/Imageconverter/AppModel.swift`, `SidebarView.swift` (preset bar above the drop zone), `FileStepEditors.swift` (`SetFieldRow`: `.onChange(of: text)` refreshes the draft, which was parked in milestone 3)
- Test: `Tests/ImageconverterCoreTests/PresetSessionTests.swift`

**Interfaces:**
- `public struct PresetSession: Equatable, Sendable { public private(set) var selected: Preset?; public var pipeline: Pipeline; public var isModified: Bool { … }`
  - `public enum Switch { case done, needsConfirmation }`
  - `mutating func select(_ preset: Preset, force: Bool = false) -> Switch`
  - `mutating func resetToPreset()`
  - `func saveTarget() -> SaveTarget` (`.overwrite(id)` for a user preset, `.saveAs` for a built-in or none)
  - `mutating func didSave(_ preset: Preset)`
- `isModified` compares `pipeline` with `selected?.pipeline`. With no preset selected (an ad hoc pipeline), it is never "modified".
- **App:**
  - `AppModel` holds a `PresetStore` and a `PresetSession`, and persists the selected preset id under UserDefaults `"selectedPresetID"`.
  - On launch, if a preset is selected and the saved `currentPipeline` differs, the session restores the saved pipeline as modified.
  - **PresetBar:**
    - a picker listing built-ins, a divider, then user presets, plus "None (ad hoc)";
    - a "•" when modified;
    - Save (⌘S; Save as for built-ins), "Save as…" (a sheet with a name field and inline validation errors);
    - "Rename…" and "Delete…" (confirmation "Delete preset <name>?" Delete/Cancel), disabled for built-ins;
    - "Reset to preset", enabled when modified;
    - a switch that returns `needsConfirmation` shows the "Discard changes to <name>?" dialog.
  - Skipped preset files show once as a toast: "Skipped 1 preset file", with the reasons in its description.

- [ ] **Step 1: Write the failing session tests.**
  - Selecting with no edits → done.
  - Selecting after an edit → needsConfirmation, and `force` → done with the pipeline replaced.
  - Reset restores the preset's pipeline.
  - Save target: built-in → saveAs, user preset → overwrite.
  - `didSave` clears modified.
  - Ad hoc is never modified.
- [ ] **Step 2: Run the tests.** Expected: fail.
- [ ] **Step 3: Implement the session, then the UI.**
- [ ] **Step 4: Verify.** Run `swift build`, `swift test` and `swiftlint --strict`.
- [ ] **Step 5: Commit** `feat: presets in the sidebar (save, save as, rename, delete, reset)`.

---

### Task 3: Preview renderer (Core)

**Files:**
- Create: `Sources/ImageconverterCore/PreviewRenderer.swift`
- Test: `Tests/ImageconverterCoreTests/PreviewRendererTests.swift` (and a batch test for overwrite mode with the watermark image as an input, parked in milestone 4)

**Interfaces:**
- `public struct PreviewResult: @unchecked Sendable { public let before: CGImage; public let after: CGImage; public let sourceName: String; public let outputName: String; public let sourceSize: (Int, Int); public let outputSize: (Int, Int) }` (`before` and `after` downscaled to fit `displayMax`)
- `public enum PreviewOutcome: Sendable { case ready(PreviewResult), failed(reason: String) }`
- `public actor PreviewRenderer`:
  - `init(maxPixels: Int = ImageLoader.defaultMaxPixels, displayMax: Int = 1600)`
  - `func render(item: InputItem, index: Int, pipeline: Pipeline) async -> PreviewOutcome`
  - It caches the decoded source for the last item URL and the `WatermarkAssets` for the last set of watermark paths.
  - It checks `Task.isCancelled` before and after the expensive steps; on cancellation it returns `.failed(reason: "Cancelled")`, which callers ignore.
  - The output name comes from the rename template (`counterStart + index`) and the output extension.
  - It uses the same load → apply → (metadata is not visual) path as the batch, but doesn't encode.

- [ ] **Step 1: Write the failing tests.**
  - Resize maxWidth 400 on 800×600 → outputSize (400, 300), and the after image fits within `displayMax`.
  - Rename pattern → `outputName` `"trip_01.jpg"`.
  - Missing watermark image → `.failed("Couldn't read the watermark image")` (Review Focus 4).
  - Unreadable source → failed with the loader's reason.
  - The cached source isn't decoded twice for the same URL (internal counter).
  - Cancellation: start a render of a large noise image, cancel its task immediately, and get either the cancelled outcome or a completed one, never a crash (Review Focus 3, core side).
  - Batch overwrite with the watermark file itself among the inputs (milestone 4 park): the run succeeds, and the stamp on the second image is the original logo.
- [ ] **Step 2: Run the tests.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test` twice.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): preview renderer`.

---

### Task 4: Preview pane, filmstrip, docs

**Files:**
- Create: `Sources/Imageconverter/PreviewPane.swift`, `Sources/Imageconverter/Filmstrip.swift`
- Modify: `Sources/Imageconverter/ImageconverterApp.swift` (two-column layout with a collapsible preview; the window widens or narrows when it is toggled), `AppModel.swift` (`selectedIndex`, preview state, debounced render task, collapsed flags persisted under `"previewCollapsed"` and `"pipelineCollapsed"`), `FileStepEditors.swift` (the rename example uses the selected item when there is one), `README.md`, `CHANGELOG.md`, `CLAUDE.md`

**Behaviour:**
- **Preview pane (right, `lgCard`):**
  - Header: "Preview", with a "Hide preview" button (⌥⌘P; menu item View → Show/Hide Preview).
  - Two images side by side with "Before" / "After" chips; stacked when narrower than 560 pt.
  - Then a line: `IMG_2041.HEIC 4032 × 3024 → 2026-11-13_iPhone 15 Pro_001.jpg 1600 × 1200`.
  - A `ProgressView` spinner overlay while rendering, keeping the previous result visible.
  - On failure, the after side shows the reason in the warn colour.
  - Empty batch: the hint "Add images to see a preview".
- **Filmstrip** (bottom of the pane): a horizontal `LazyHStack` of 56 pt thumbnails (64 px, off the main actor, cached by URL).
  - Clicking selects; ←/→ move the selection when the filmstrip has focus; the selected item gets an accent outline.
  - Each thumbnail's accessibility label is the file name.
- **Rendering:** a change to the selection or the pipeline cancels the previous render task, waits 300 ms, then renders the selected item with the current pipeline. Results are applied only if they belong to the latest request (a generation counter).
- **Collapsed preview:** the window keeps the sidebar only (min width 340). The state persists.
- **Docs:**
  - README: Features (presets and preview), how-tos "Save a preset" and "Preview before running", the Configuration table (presets folder, built-ins listed with their settings), and the screenshot-grid placeholder kept.
  - CHANGELOG Unreleased: "Presets (save, save as, rename, delete, reset; three built-ins) and a collapsible before/after preview with a filmstrip of the batch."
  - CLAUDE.md layout.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** Run `swift build && swift test && swiftlint --strict`. Expected: 0 warnings, all pass, 0 violations.
- [ ] **Step 3: Smoke-launch.** Run `swift run` for 5 s, then kill it and leave nothing running. In the report, list the interactive checks not done.
- [ ] **Step 4: Commit** `feat(app): preview pane and filmstrip`.
