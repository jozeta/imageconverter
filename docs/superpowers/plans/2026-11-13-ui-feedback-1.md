# UI feedback round 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply Johan's first hands-on feedback (2026-11-13): output modes redesigned and moved into
the Output row, rename find/replace, a file-size estimate, tighter pipeline rows with drag handles,
edge handles that toggle the pipeline and the preview with smooth window resizing, and a two-column
info table plus progress bar in the preview.

**Architecture:** Core changes first (planner rules, rename find/replace, size estimate, preview
paths), each with tests; then the SwiftUI changes on top. No new dependencies.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit (NSWindow animation), ImageIO, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-13-imageconverter-design.md`. Where this plan differs from
the spec, the plan is Johan's newer decision (feedback of 2026-11-13) and wins: new-folder output
is flat; same-folder suffix only on a name clash with the original, default `_new`; overwrite
disables rename; output mode moves from the Settings window into the Output row.

## Global Constraints

- macOS 14+, Swift 5.10, SwiftPM; Apple frameworks only; don't edit `Sources/Imageconverter/DesignSystem/LadaGlass.swift`.
- Use Låda Glass `lg-` components and tokens (`LadaGlass.Spacing`, `.Colors`, `.Typography`, `.lg(...)` button styles).
- Every control keeps a VoiceOver label and is keyboard reachable (Tab / Space); drag-only actions keep a keyboard/menu alternative.
- `swift build` with 0 warnings, `swift test` green, `swiftlint --strict` 0 violations.
- Never lose files: the FileCommitter / Trash rules stay as they are.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage only files you changed.

## Review Focus

1. Same folder, HEIC → JPEG: `IMG.heic` becomes `IMG.jpg` (no suffix); a second run finds `IMG.jpg` and writes `IMG_2.jpg`, never touching the original.
2. Same folder, JPEG → JPEG with no rename: the destination equals the source, so the suffix is added (`IMG_new.jpg`); the original is never replaced.
3. New folder with a dropped folder tree that holds two `a.jpg` in different subfolders: both land flat in the chosen folder as `a.jpg` and `a_2.jpg`.
4. A regex like `(` or one that matches the empty string (`x*`) must not crash, hang or produce an empty name.
5. Toggling the preview or the pipeline repeatedly and fast must not leave the window at a wrong size or flicker.

---

### Task 1: Output planner rules

**Files:**
- Modify: `Sources/ImageconverterCore/OutputPlanner.swift`
- Test: `Tests/ImageconverterCoreTests/OutputPlannerTests.swift` (update tests that assume mirrored subfolders, always-on suffix or rename under overwrite)

**Interfaces:**
- Produces: `OutputPlanner.plan(_:format:mode:baseNames:fileExists:)` unchanged signature, new rules below. `OutputPlanner.defaultSuffix = "_new"`.

Rules:
- `.newFolder(root)`: destination directory is always `root` (ignore `item.relativeDirectory`). Clashes get `_2`, `_3`, … as before.
- `.sameFolder(suffix)`: the name is `baseNames?[i] ?? source name`. The (sanitised) suffix is appended **only** when `<name>.<ext>` in the source folder is the source file itself (case-insensitive compare). Otherwise no suffix; other clashes get `_2`.
- `.overwrite`: `baseNames` is ignored (rename is disabled in overwrite mode); everything else as today.

- [ ] Step 1: Write failing tests: `testNewFolderIsFlat` (two `a.jpg` from different `relativeDirectory` → `root/a.jpg`, `root/a_2.jpg`), `testSameFolderNoSuffixWhenFormatChanges` (`IMG.heic` → `IMG.jpg`), `testSameFolderSuffixWhenNameEqualsOriginal` (`IMG.jpg` → `IMG_new.jpg` with suffix `_new`; `img.JPG` source also gets it), `testSameFolderSuffixWhenRenamedToOriginalName` (baseNames `["IMG"]` for `IMG.jpg`), `testSameFolderExistingFileGetsNumber` (`IMG.heic`, existing `IMG.jpg` → `IMG_2.jpg`), `testOverwriteIgnoresBaseNames`.
- [ ] Step 2: Run `swift test --filter OutputPlannerTests`, expect failures.
- [ ] Step 3: Implement. Also update any other test files that relied on the old rules (`BatchRunnerTests`, `FileStepsBatchTests`, `PreviewRendererTests`, …).
- [ ] Step 4: `swift test` green.
- [ ] Step 5: Commit `feat(core): flat new-folder output, suffix only on a clash with the original, no rename when overwriting`.

### Task 2: Rename find and replace

**Files:**
- Modify: `Sources/ImageconverterCore/FileSteps.swift` (`RenameOptions`), `Sources/ImageconverterCore/RenameRendering.swift`, `Sources/ImageconverterCore/RenameExample.swift`, `Sources/ImageconverterCore/StepSummary.swift` if the summary should mention it
- Create: `Sources/ImageconverterCore/NameReplacement.swift`
- Test: `Tests/ImageconverterCoreTests/NameReplacementTests.swift`

**Interfaces:**
- Produces: `RenameOptions.findText: String` (default `""`), `RenameOptions.replaceText: String` (default `""`), `RenameOptions.useRegex: Bool` (default `false`); lenient decoding (missing → default).
- Produces: `public enum NameReplacement { public static func apply(_ name: String, find: String, replace: String, regex: Bool) -> String; public static func regexError(_ pattern: String) -> String? }`.

Rules: empty `find` → name unchanged. Plain mode replaces every occurrence, case-sensitive. Regex mode uses `NSRegularExpression` with `$1` templates; an invalid pattern leaves the name unchanged and `regexError` returns a short message (e.g. "Invalid regular expression"). Applied to the rendered base name (rename on) and, when rename is on, to the source name when the pattern is `{name}`; it runs before the existing sanitising so a replacement cannot add `/`, `:`, control or bidi characters or exceed the length limits. If the result is empty after sanitising, the existing fallback (original name, then `image`) applies. Find/replace only applies when the Rename step is enabled.

- [ ] Step 1: Failing tests: `testPlainReplacesAll` (`"a-b-c"`, `-`→`_` = `"a_b_c"`), `testEmptyFindIsNoop`, `testRegexGroups` (`"IMG_1234"`, `IMG_(\d+)` → `photo-$1` = `"photo-1234"`), `testInvalidRegexIsNoop` (`"("` → unchanged, `regexError("(") != nil`), `testEmptyMatchRegexDoesNotHang` (`x*` → completes), `testReplacementCannotAddSlash` (via `RenameRendering`/`RenameExample`, replace with `"a/b"` gives no `/` in the final name), `testDecodesOldRenameOptions` (JSON without the new keys).
- [ ] Step 2: Run, expect failures.
- [ ] Step 3: Implement; batch and preview both get it through `RenameRendering`, the live example through `RenameExample`.
- [ ] Step 4: `swift test` green.
- [ ] Step 5: Commit `feat(core): find and replace (plain or regex) in the rename step`.

### Task 3: Size estimate and preview paths

**Files:**
- Modify: `Sources/ImageconverterCore/BatchRunner.swift` (factor the load → apply → metadata → encode part of `convert` into a reusable function), `Sources/ImageconverterCore/PreviewRenderer.swift`
- Create: `Sources/ImageconverterCore/SizeEstimator.swift`
- Test: `Tests/ImageconverterCoreTests/SizeEstimatorTests.swift`, `Tests/ImageconverterCoreTests/PreviewRendererTests.swift`

**Interfaces:**
- Produces: `public struct EncodedPreview: @unchecked Sendable { public let bytes: Int; public let original: CGImage; public let encoded: CGImage }` and `public enum SizeEstimator { public static func render(item: InputItem, pipeline: Pipeline, maxPixels: Int = ImageLoader.defaultMaxPixels) throws -> EncodedPreview }`: `bytes` is the byte count of exactly what the batch would write for this item (full size, real encoder, nothing written to disk); `original` is the full-size upright source; `encoded` is those encoded bytes decoded again (so JPEG/HEIC artifacts are visible when zoomed).
- Produces: `PreviewResult.outputURL: URL` (the planned destination, via `OutputPlanner`, nil-safe: when `mode` is nil the directory is the source's), `PreviewResult.sourceFileSize: Int?` (bytes on disk).

- [ ] Step 1: Failing tests: `testEstimateMatchesWrittenFile` (generate a JPEG, `render`, compare `bytes`, run `BatchRunner` to a temp folder, sizes equal), `testEstimateChangesWithQuality` (quality 0.3 < quality 0.95), `testEstimateThrowsForUnreadable`, `testPreviewResultHasOutputURLAndSourceSize`.
- [ ] Step 2: Run, expect failures.
- [ ] Step 3: Implement; `convert` uses the shared encode function so they can't drift apart.
- [ ] Step 4: `swift test` green.
- [ ] Step 5: Commit `feat(core): file size estimate and output path for the preview`.

### Task 4: Output row: mode dropdown, size estimate, rename find/replace UI

**Files:**
- Modify: `Sources/Imageconverter/PipelineSection.swift` (Output row), `Sources/Imageconverter/AppSettings.swift`, `Sources/Imageconverter/FileStepEditors.swift` (Rename editor, Rename row disabled in overwrite), `Sources/Imageconverter/ImageconverterApp.swift`, `Sources/Imageconverter/AppModel.swift` or `AppModel+Preview.swift` (estimate task)
- Delete: `Sources/Imageconverter/SettingsView.swift` (the Settings window had only output settings; remove the `Settings` scene)

**Interfaces:**
- Consumes: Task 1 rules, Task 2 `RenameOptions` fields and `NameReplacement.regexError`, Task 3 `SizeEstimator.render`.
- Produces: `AppModel.sizeEstimate: SizeEstimate?` where `struct SizeEstimate { let item: URL; let original: Int?; let output: Int?; let full: EncodedPreview? }` (`full` feeds Task 8's zoom; keep at most one, drop it when the selection changes) for the selected item (used by Task 7's preview table), recomputed 400 ms after the selected item, pipeline or output settings change, off the main actor, cancelling the previous computation; nil while running or with no items.

UI (inside the Output row, in this order):
1. Format picker (as now); quality slider (as now); directly under the slider a muted line `Original 4.2 MB → about 1.1 MB` (`ByteCountFormatter`, `.file`; "Estimating…" while computing; "—" when it failed). Show the line for every format (under the format/compression controls when there is no slider).
2. A `Picker` (menu style) labelled "Save to" with three options, in this order: "Overwrite original files", "Same folder as original", "New folder".
   - Overwrite: selecting it asks once with the existing confirmation dialog text (move it from `SettingsView`); cancel keeps the old mode. A muted note says the Rename step is off while overwriting.
   - Same folder: a text field "Added when the name is unchanged" bound to the suffix, default `_new` (`AppSettings` default changes from `_converted` to `OutputPlanner.defaultSuffix`; a stored value is kept).
   - New folder: a "Choose folder…" button and the chosen path (middle-truncated mono text, "No folder chosen" otherwise).
3. The Rename row is disabled (greyed, toggle off-looking, can't expand) in overwrite mode, with the help text "Not available when overwriting originals". The batch already ignores rename names there (Task 1).
4. Rename editor gets "Find" and "Replace with" fields and a "Regular expression" checkbox under the pattern; an invalid regex shows `regexError` in `LadaGlass.Colors.badText` under the fields. The live example reflects find/replace.

- [ ] Step 1: Implement; remove the Settings scene and `SettingsView.swift`; ⌘, disappears.
- [ ] Step 2: `swift build` 0 warnings, `swift test`, `swiftlint --strict`.
- [ ] Step 3: Launch `.build/debug/Imageconverter`, take `screencapture -x` screenshots of the Output row in each mode, look at them, then quit the app (`pkill -f "Imageconverter$"`). Put screenshots in the scratch dir given in the dispatch, not the repo.
- [ ] Step 4: Commit `feat(app): output mode dropdown in the Output row, size estimate, rename find and replace`.

### Task 5: Pipeline rows

**Files:**
- Modify: `Sources/Imageconverter/PipelineSection.swift`, `Sources/Imageconverter/FileStepEditors.swift` (`FileStepRow`), `Sources/Imageconverter/StepEditors.swift`, `Sources/Imageconverter/StepControls.swift`, `Sources/Imageconverter/WatermarkEditor.swift` (spacing only)

Changes:
1. "+ Add step" menu moves directly under the "Pipeline · N steps" header, above the steps. A newly added step is **collapsed**.
2. Each image-step row: a drag handle (`line.3.horizontal`, open-hand cursor on hover, the whole handle is the drag source with a row-shaped drag preview, an accent insertion line where it will drop) replaces the `…` menu for moving. A small remove button (`xmark`, ghost, label "Remove <step>") replaces the menu's Remove. Keep a context menu with Move Up / Move Down / Remove and add `accessibilityAction`s "Move up"/"Move down" so moving stays keyboard and VoiceOver reachable.
3. When a step (image step or file step) is switched off, its disclosure chevron is disabled and greyed out and the row collapses; switching it on does not auto-expand.
4. Less vertical space: row padding `Spacing.s` vertical (keep `Spacing.m` horizontal), editor stacks use `Spacing.xs`/`Spacing.s` instead of `Spacing.m`, the gap between rows `Spacing.xs`. Applies to step rows, file step rows and the Output row.

- [ ] Step 1: Implement. Drag and drop must reorder using the existing `model.moveStep(_:to:)`.
- [ ] Step 2: Build/test/lint as in Global Constraints.
- [ ] Step 3: Launch the app, screenshot the pipeline with 3 steps (one off), check spacing and the greyed chevron, then quit the app.
- [ ] Step 4: Commit `feat(app): drag handles, tighter pipeline rows, add-step menu on top, disabled steps can't expand`.

### Task 6: Edge handles and smooth window resizing

**Files:**
- Create: `Sources/Imageconverter/EdgeHandle.swift`
- Modify: `Sources/Imageconverter/ImageconverterApp.swift`, `Sources/Imageconverter/AppModel+Preview.swift`, `Sources/Imageconverter/SidebarView.swift`, `Sources/Imageconverter/PreviewPane.swift`, `Sources/Imageconverter/PipelineSection.swift`

**Interfaces:**
- Produces: `struct EdgeHandle: View { enum Edge { case trailing, bottom }; let edge: Edge; let pointsOutward: Bool; let label: String; let action: () -> Void }`: a small capsule grab handle (about 6 × 44 pt vertical / 44 × 6 pt horizontal, `LadaGlass.Colors.border` fill, accent on hover, a tiny chevron showing the direction), a focusable button with the VoiceOver label.

Changes:
1. Remove the "Show preview", "Hide preview" and "Collapse/Expand" text buttons.
2. Preview handle: vertical handle centred vertically on the border between the sidebar and the preview when open; on the window's right edge when the preview is hidden. Click toggles (same as ⌥⌘P, which stays).
3. Pipeline handle: horizontal handle centred on the bottom edge of the sidebar. Click collapses/expands the pipeline. Add a View menu item "Collapse Pipeline"/"Expand Pipeline" (⌥⌘L) for keyboard users.
4. Window resizing: toggling the preview animates the window width; toggling the pipeline animates the window height to fit the sidebar content (clamped to the minimum height 420 and the screen's visible frame; keep the top edge fixed). Use `NSAnimationContext` with duration 0.2 s and ease-in-ease-out (`window.animator().setFrame`). No jump or flicker: the preview pane must not be inserted or removed mid-animation in a way that forces a relayout at the wrong size (e.g. keep the pane in the hierarchy and clip it, or reveal it after/with the frame animation, and drop its min width while collapsed). Ignore toggles while an animation is running, or coalesce them so the window ends at the correct size.
5. Measure the sidebar's content height with a preference key to compute the pipeline target height.
6. No empty space around the panels (Johan, 2026-11-13): the window can't be resized larger than its panels need. The sidebar has a fixed width; with the preview hidden the window width is fixed to the sidebar. The window's maximum height is the sidebar's content height (measured, see 5), so there is never blank backdrop under the sidebar panel; the window height follows that content height automatically (animated) when it changes (pipeline collapse, steps added/removed/expanded), clamped to the screen's visible frame (the sidebar scrolls only when the screen is too short). With the preview open, only the width is user-resizable (preview min width 420). Set `window.contentMaxSize`/`contentMinSize` (or `windowResizability(.contentSize)` with explicit frames) accordingly.

- [ ] Step 1: Implement.
- [ ] Step 2: Build/test/lint.
- [ ] Step 3: Launch the app, toggle the preview and the pipeline several times quickly via the menu (`osascript` with System Events, or AppleScript `click menu item`), take screenshots after each, confirm the final sizes are correct and nothing overlaps; quit the app.
- [ ] Step 4: Commit `feat(app): edge handles toggle the preview and the pipeline with animated window resizing`.

### Task 7: Preview info table and progress bar, docs

**Files:**
- Modify: `Sources/Imageconverter/PreviewPane.swift`, `Sources/Imageconverter/SidebarView.swift`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: Task 3 `PreviewResult.outputURL`/`sourceFileSize`, Task 4 `AppModel.sizeEstimate`.

Changes:
1. Replace the one-line info with a `Grid`: header row (empty, "Original", "Result"), then rows "Name", "Folder" (full folder path, middle-truncated, selectable, `help` shows the full path), "Dimensions" (`W × H`), "Size" (original bytes; result estimate or "Estimating…"). Labels muted, values mono.
2. While a batch runs, a progress bar (`ProgressView(value:total:)`, with `completed / total` text and the Cancel button) sits directly above the table; the space between the images and the table stays above the bar. When the preview is hidden, the sidebar shows the progress as today.
3. README (output modes, rename find/replace, size estimate, handles, ⌥⌘L, no Settings window), CHANGELOG Unreleased, CLAUDE.md layout (EdgeHandle, SizeEstimator, NameReplacement, SettingsView removed).

- [ ] Step 1: Implement.
- [ ] Step 2: Build/test/lint.
- [ ] Step 3: Launch, add a few images (via the open panel is not scriptable; instead pass none and check layout with an empty batch, and have the reviewer check by reading), screenshot, quit.
- [ ] Step 4: Commit `feat(app): original/result table and progress bar in the preview; docs`.

### Task 8: Synced pinch zoom and pan in the preview

**Files:**
- Create: `Sources/Imageconverter/ZoomableComparison.swift`
- Modify: `Sources/Imageconverter/PreviewPane.swift`, `Sources/Imageconverter/ImageconverterApp.swift` (View menu items)

**Interfaces:**
- Consumes: `PreviewResult.before/after` (fit-size images), `AppModel.sizeEstimate?.full` (`EncodedPreview.original/encoded`, full size, only when its `item` is the selected one).
- Produces: `struct ZoomState: Equatable { var scale: CGFloat /* 1 = fit */; var center: CGPoint /* unit coordinates 0…1 of the image */ }` held once in the pane and shared by both sides.

Behaviour:
1. Trackpad pinch on either image zooms both, around the pinch location; two-finger scroll (and click-drag) pans both; the two sides always show the same region. Zoom range: fit (1) up to 8× actual pixels. Double-click resets to fit.
2. Pinch and scroll come from an `NSViewRepresentable` overlay that overrides `magnify(with:)` and `scrollWheel(with:)` (SwiftUI's `MagnifyGesture` alone doesn't give two-finger panning); it must not swallow scroll events when at fit scale (pass them on).
3. When zoomed past fit, draw the full-size images from `sizeEstimate.full` once available (`original` left, `encoded` right) so real encoder artifacts are visible; until then, use the fit-size images scaled up. Above 100 % actual pixels use `.interpolation(.none)`.
4. Keyboard and menu: View › Zoom In (⌘+), Zoom Out (⌘−), Actual Size (⌘0... use ⌥⌘0 if ⌘0 is taken), Zoom to Fit (⌘9 or similar unused); VoiceOver: the image group has an `accessibilityZoomAction`.
5. Zoom resets to fit when the selected image changes; it stays when only settings change (so you can watch quality change on a zoomed region).
6. Show the zoom level as a small muted chip (e.g. "200 %") while zoomed.

- [ ] Step 1: Unit-test the pure maths in Core or a small helper that takes no SwiftUI: put `ZoomMath` (clamping the centre so the image edge never leaves the view, zooming around an anchor point) in `Sources/ImageconverterCore/ZoomMath.swift` with tests `testZoomAroundAnchorKeepsAnchorFixed`, `testCenterClampedAtEdges`, `testScaleClampedToRange`.
- [ ] Step 2: Implement the view.
- [ ] Step 3: Build/test/lint; launch and screenshot with the menu zoom commands; quit the app.
- [ ] Step 4: Commit `feat(app): synced pinch zoom and pan in the before/after preview`.

### Task 9: Adjust step (tone, colour, detail)

**Files:**
- Create: `Sources/ImageconverterCore/Adjustments.swift` (options model + the Core Image render), `Sources/Imageconverter/AdjustEditor.swift`
- Modify: `Sources/ImageconverterCore/Pipeline.swift` (`StepKind.adjust`, operation case, `apply`, `peakPixels`), `Sources/ImageconverterCore/StepSummary.swift`, `Sources/Imageconverter/StepEditors.swift` (route to the editor), README/CHANGELOG/CLAUDE.md
- Test: `Tests/ImageconverterCoreTests/AdjustmentsTests.swift`

Johan (2026-11-13): "add a new pipeline item; it should give the user the ability to edit contrast, hue, saturation, exposure, brilliance, highlights, shadows, brightness, black point, vibrance, warmth, tint, sharpness, definition, noise reduction".

**Interfaces:**
- Produces: `public struct AdjustOptions: Codable, Equatable, Sendable` with these `Double` fields, every one defaulting to 0 (neutral) and clamped to its range on decode (lenient: missing → 0): `exposure` (−100…100), `brilliance` (−100…100), `highlights` (−100…100), `shadows` (−100…100), `contrast` (−100…100), `brightness` (−100…100), `blackPoint` (−100…100), `saturation` (−100…100), `vibrance` (−100…100), `warmth` (−100…100), `tint` (−100…100), `hue` (−180…180, degrees), `sharpness` (0…100), `definition` (0…100), `noiseReduction` (0…100). `public var isNeutral: Bool`. `public static let ranges` (field → range) for the editor.
- Produces: `StepKind.adjust` (display name "Adjust"), operation case `.adjust(AdjustOptions)`; `public enum Adjustments { public static func apply(_ options: AdjustOptions, to image: CGImage) throws -> CGImage }`.

Rendering (Core Image, one `CIContext` per call or a shared one created once; working space linear extended sRGB; output rendered back to **the input image's colour space and bit depth**, alpha preserved, opaque stays opaque; neutral options return the input unchanged without rendering). Fixed order and mapping (v = slider value):
1. Exposure: `CIExposureAdjust` EV = v / 50 (±2 EV).
2. Highlights / shadows: `CIHighlightShadowAdjust` highlightAmount = 1 − max(0, −v)/100·… — use: highlights v<0 recovers (highlightAmount = 1 + v/100 → 0…1), v>0 boosts via a tone curve lift of the top quarter; shadows v (−100…100) → shadowAmount = v/100.
3. Brilliance: a balanced tone curve: lifts shadows and compresses highlights by v/200 each (`CIToneCurve`), negative does the opposite.
4. Black point: `CIToneCurve` first point x = max(0, v/100·0.15) mapping to 0 for v>0 (deeper blacks); v<0 lifts y0 = −v/100·0.15.
5. Contrast / brightness / saturation: `CIColorControls` contrast = 1 + v/100·0.5 (0.5…1.5), brightness = v/100·0.25, saturation = 1 + v/100 (0…2).
6. Vibrance: `CIVibrance` amount = v/100.
7. Warmth / tint: `CITemperatureAndTint` neutral (6500, 0) → targetNeutral (6500 − warmth·20, tint·1.0) (warmth +100 = warmer, i.e. lower target temperature is the CI convention to warm; verify direction with a test).
8. Hue: `CIHueAdjust` angle = v degrees in radians.
9. Noise reduction: `CINoiseReduction` noiseLevel = v/100·0.04, sharpness 0.4.
10. Definition: `CIUnsharpMask` radius = 0.02·min(w,h) (local contrast), intensity = v/100·0.6.
11. Sharpness: `CISharpenLuminance` sharpness = v/100·1.5, radius 1.5.
Mapping constants may be tuned if a test or a screenshot shows them clearly wrong; record any change in the report.

`peakPixels`: count an adjust step as 3 working copies of its input size (CI intermediates).

- [ ] Step 1: Failing tests: `testNeutralReturnsSameImage` (identity: same object or same pixels), `testExposurePositiveBrightens` (mean luminance up), `testSaturationMinus100IsGray` (R≈G≈B within 2/255), `testWarmthPositiveIsWarmer` (R/B ratio rises on a gray image), `testHue180SwapsRedTowardsCyan`, `testKeepsSizeColorSpaceAndAlpha` (P3 16-bit with alpha in → same size, P3, 16 bpc, alpha kept; opaque in → opaque out), `testDecodesClampsAndDefaults` (missing keys → 0, out-of-range clamped), `testPipelineRunsAdjustStep` (through `Pipeline.apply`).
- [ ] Step 2: Run, expect failures.
- [ ] Step 3: Implement Core.
- [ ] Step 4: Editor: a compact list of labelled sliders grouped "Light" (Exposure, Brilliance, Highlights, Shadows, Contrast, Brightness, Black point), "Colour" (Saturation, Vibrance, Warmth, Tint, Hue), "Detail" (Sharpness, Definition, Noise reduction); each row: label, slider, value text, and double-click on the label (plus a small reset button per group) resets to 0; VoiceOver label and value per slider; slider changes feed the existing debounced preview. Summary line: the non-neutral fields, e.g. "exposure +20, contrast +10" or "no changes".
- [ ] Step 5: Build/test/lint; screenshot the editor and a preview with a few adjustments (use the DEBUG `-debugAddFiles` argument if Task 8 added it); docs.
- [ ] Step 6: Commit `feat: Adjust step (exposure, brilliance, highlights, shadows, contrast, brightness, black point, saturation, vibrance, warmth, tint, hue, sharpness, definition, noise reduction)`.

---

## Compression round (Johan, 2026-11-13; WebP output and chroma subsampling skipped: they need third-party encoders)

### Task 10: Encoder options: full quality range, progressive JPEG, PNG optimisation, AVIF

**Files:** Modify `Sources/ImageconverterCore/OutputFormat.swift`, `Sources/ImageconverterCore/ImageEncoder.swift`; Test `Tests/ImageconverterCoreTests/ImageEncoderTests.swift`, `OutputFormatTests.swift`

**Interfaces:**
- `OutputFormat.avif` (UTType `public.avif`, extension `avif`, display "AVIF", `supportsQuality`), listed by `available()` only when `CGImageDestinationCopyTypeIdentifiers()` contains it (as for the other optional formats). HEIC-like handling (alpha kept).
- `OutputSettings.progressive: Bool` (default false; JPEG only: `kCGImagePropertyJFIFDictionary` → `kCGImagePropertyJFIFIsProgressive`), `OutputSettings.optimizePNG: Bool` (default true; PNG only: encode with each of the ImageIO PNG filter choices `IMAGEIO_PNG_FILTER_NONE`, `_SUB`, `_UP`, `_AVG`, `_PAETH`, `IMAGEIO_PNG_ALL_FILTERS` via `kCGImagePropertyPNGCompressionFilter` and keep the smallest; lossless, pixels identical). Lenient decode (missing → default). Quality range is now 0…1 everywhere (slider 0–100 %).
- [ ] Tests: `testProgressiveJPEGFlag` (re-read JFIF IsProgressive true), `testOptimizedPNGNotLargerAndIdenticalPixels`, `testAVIFRoundTripWhenAvailable` (skip with `XCTSkip` when unavailable), `testQualityZeroEncodes`, `testDecodesOldOutputSettings`.
- [ ] Implement, `swift test`, commit `feat(core): progressive JPEG, PNG optimisation, AVIF output, full quality range`.

### Task 11: Compression modes: quality, target size, maximum size, smart

**Files:** Create `Sources/ImageconverterCore/CompressionSearch.swift`, `Sources/ImageconverterCore/ImageSimilarity.swift`; Modify `OutputFormat.swift` (`OutputSettings`), `BatchRunner.swift` (`encodeItem` uses the search so batch and estimate agree); Test `CompressionSearchTests.swift`, `ImageSimilarityTests.swift`

**Interfaces:**
- `public enum CompressionMode: Codable, Equatable, Sendable { case quality; case targetSize(bytes: Int); case maxSize(bytes: Int); case smart }` on `OutputSettings.compression` (default `.quality`; lenient decode). Applies only to formats with `supportsQuality`; other formats ignore it.
- `public enum CompressionSearch { public static func encode(_ image: CGImage, properties: [String: Any], settings: OutputSettings) throws -> (data: Data, quality: Double?, note: String?) }`.
- Rules: `.quality` = one encode at `settings.quality`. `.targetSize(b)`: binary search quality in 0…1 (at most 8 encodes, tolerance 1 %) for the highest quality whose size ≤ b; if even quality 0 is larger, write quality 0 and return note "Couldn't reach <size>; smallest is <size>". `.maxSize(b)`: encode at `settings.quality`; if > b, binary search downwards as above; if quality 0 is still > b the file **fails** with `ConversionError.encodeFailed`-style reason "Can't get under <size> (smallest is <size>)". `.smart`: binary search (≤ 7 encodes) the lowest quality in 0.40…0.95 whose decoded result has SSIM ≥ 0.985 against the pre-encode image (luma, both downsampled to ≤ 1024 px long edge); `ImageSimilarity.ssim(_:_:) -> Double`.
- `BatchReport` per-file notes surface in the failure/notes list (a note is not a failure). `SizeEstimator`/`EncodedPreview` gain `quality: Double?` (the chosen quality) and `note: String?`.
- [ ] Tests: `testTargetSizeHitsBelowTarget`, `testTargetSizeUnreachableReturnsNote`, `testMaxSizeKeepsQualityWhenSmallEnough`, `testMaxSizeFailsWhenImpossible`, `testSmartPicksLowerQualityForFlatImage` (flat gradient → lower quality than a noisy image), `testSSIMIdenticalIsOne`, `testSSIMNoisyLower`, `testEstimateEqualsBatchWithTargetSize`.
- [ ] Implement, commit `feat(core): target size, maximum size and smart compression`.

### Task 12: Compression report and percentages

**Files:** Modify `BatchRunner.swift` (`BatchReport.inputBytes`, `.outputBytes` summed over written files; per-file `BatchResultEntry { source, destination, inputBytes, outputBytes, note }`), `SidebarView.swift`/`PreviewPane.swift`/`PipelineSection.swift` (app), `AppModel.swift`; Test `BatchRunnerTests.swift`
- Size line under the quality controls and the preview table's Size row show the change as a percentage: `4.2 MB → about 1.1 MB (−74 %)` (or `+12 %`).
- After a run: toast "Converted 24 images · saved 31.2 MB (62 %)" (or "grew by …"), and a collapsible "Report" section in the sidebar (where the skipped list is) with totals and one row per file (name, before → after, %), notes included; it stays until the next run or Clear.
- [ ] Test `testReportCountsBytes`; implement; commit `feat: compression report and size percentages`.

### Task 13: Output row UI for compression

**Files:** Modify `Sources/Imageconverter/PipelineSection.swift` (Output row; split into `OutputRow.swift` if it grows past ~250 lines)
- Quality slider 0–100 %. For quality formats a "Compression" picker: "Quality", "Target size", "Maximum size", "Smart"; Target/Maximum show a number field + unit picker (KB/MB, 1 KB = 1000 B as Finder shows) ; Smart shows a muted note "Picks the lowest quality that still looks the same". "Progressive" toggle for JPEG; "Optimise PNG" toggle for PNG; AVIF appears in the format list when available. The size estimate line shows the chosen quality when the mode searches ("about 1.1 MB at 74 %"). VoiceOver labels on all.
- [ ] Build/test/lint, screenshot each mode, commit `feat(app): compression modes in the Output row`.

## Resize round (Johan, 2026-11-13)

### Task 14: Resize model: new modes, presets, DPI, resampling

**Files:** Modify `Sources/ImageconverterCore/Pipeline.swift` (resize/crop options), `Geometry.swift`, `ImageOps.swift`, `StepSummary.swift`; Create `Sources/ImageconverterCore/SizePresets.swift`, `Sources/ImageconverterCore/Resampler.swift`; Test `GeometryTests.swift`, `ImageOpsTests.swift`, `SizePresetsTests.swift`

**Interfaces / rules** (existing modes stay and keep decoding):
- New `ResizeMode` cases: `.percent(Double)` (1…1000 %), `.longestEdge(Int)`, `.shortestEdge(Int)`, `.minimum(width: Int, height: Int)` (scale up so both sides are at least these, keeping aspect; never shrinks), `.maxBox(width: Int, height: Int)` already = fit inside (keep), `.physical(width: Double?, height: Double?, unit: PhysicalUnit, dpi: Double)` with `PhysicalUnit { inch, centimetre }` → pixels = value / (unit == .centimetre ? 2.54 : 1) × dpi, rounded; one of width/height may be nil (keep aspect). "Don't enlarge" applies to all shrinking-oriented modes as today, not to `.minimum`.
- `ResizeOptions.resampling: Resampling { lanczos, bicubic, bilinear, nearest }` (default `.lanczos`). `Resampler.scale(_ image: CGImage, to: (Int, Int), method:) throws -> CGImage`: lanczos = vImage `vImageScale_ARGB8888`/`_ARGB16U`/`_ARGBFFFF` with `kvImageHighQualityResampling` (convert via `vImageBuffer_InitWithCGImage` keeping the colour space and bit depth); bicubic = Core Image `CIBicubicScaleTransform` (B 0, C 0.75); bilinear = `CGContext` interpolation `.low`; nearest = `CGContext` interpolation `.none`. Keep colour space, bit depth, alpha/opaque rules of the current resize.
- DPI: `ResizeOptions.dpi: Double?` (nil = keep); when set (or with `.physical`), write `kCGImagePropertyDPIWidth/Height` (and TIFF/JFIF resolution) into the output properties without resampling. Applied through the metadata properties path so it works for every format that stores it.
- Crop aspect presets: `CropOptions` keeps `.aspect(width:height:)`; `SizePresets.aspectRatios` = 1:1, 4:5, 4:3, 3:2, 5:4, 16:9, 9:16, 21:9, 2:3, 3:4.
- `SizePresets.social: [SizePreset]` (name, width, height, mode = fill and crop): Instagram square 1080×1080, Instagram portrait 1080×1350, Instagram landscape 1080×566, Instagram/Facebook/TikTok story 1080×1920, Facebook post 1200×630, Facebook cover 851×315, LinkedIn post 1200×627, LinkedIn cover 1584×396, X post 1600×900, X header 1500×500, YouTube thumbnail 1280×720, Pinterest pin 1000×1500. `SizePresets.resolutions` (fit inside, don't enlarge): 720p 1280×720, 1080p 1920×1080, 1440p 2560×1440, 4K 3840×2160, 8K 7680×4320.
- [ ] Tests: each new mode's target size (`testPercent50`, `testLongestEdgePortraitAndLandscape`, `testShortestEdge`, `testMinimumUpscalesOnlyWhenSmaller`, `testPhysicalCentimetresAt300DPI` (10 cm → 1181 px), `testPhysicalOneSideKeepsAspect`), `testResamplersKeepSizeColorSpaceAndDepth` (all four, P3 16-bit), `testNearestKeepsHardEdges`, `testDPIWrittenWithoutResampling` (re-read DPIWidth 300, pixel size unchanged), `testOldResizeJSONDecodes`, `testPresetsValid` (positive sizes, unique names).
- [ ] Implement, commit `feat(core): resize by percent, edges, minimum, physical size; resampling choice; DPI; size presets`.

### Task 15: Resize and crop editors

**Files:** Modify `Sources/Imageconverter/StepEditors.swift` (split into `ResizeEditor.swift` if large)
- Resize editor: mode picker grouped "Pixels" (Max width, Max height, Fit inside, Exact size, Longest edge, Shortest edge, Minimum size), "Scale" (Percentage), "Print" (Physical size: width/height fields, unit cm/in, DPI); exact size keeps the fill choice (Stretch / Fit and pad / Fill and crop) with clear labels ("Stretch (ignore aspect ratio)", "Fit inside, pad", "Fill, crop edges"); "Keep aspect ratio" is implied by every mode except Stretch, say so in the help text. A "Presets" menu: Social media (fills Exact size + Fill and crop) and Resolutions (fills Fit inside + don't enlarge). Resampling picker (Lanczos, Bicubic, Bilinear, Nearest neighbour). "Set DPI" toggle + field (default 300 when switched on). Crop editor: aspect presets menu.
- [ ] Build/test/lint, screenshot, commit `feat(app): resize modes, presets, resampling and DPI in the editors`.
