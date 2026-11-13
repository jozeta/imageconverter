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

> Amended 2026-11-14 (reporting round): Task 12 also creates `Sources/ImageconverterCore/ProcessingReport.swift` — the one report model (`RunSummary` + per-file entries, see Task 38) that the toast, the sidebar report, jobs (Task 29) and exports (Task 38) all use. Task 29 reuses it instead of defining its own.

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

## Geometry round (Johan, 2026-11-13)

Already present: rotate 90/180/270, flip horizontal/vertical, crop, padding, canvas size, anchor (centre by default).

### Task 16: Arbitrary rotation, straighten, perspective, trim, canvas aspect (Core)

**Files:** Modify `Pipeline.swift` (options, `StepKind`, `apply`, `peakPixels`), `ImageOps.swift`, `StepSummary.swift`; Create `Sources/ImageconverterCore/Perspective.swift`, `Sources/ImageconverterCore/Trim.swift`; Tests `ImageOpsTests.swift`, `PerspectiveTests.swift`, `TrimTests.swift`

**Interfaces / rules** (old JSON keeps decoding, new fields default to "no change"):
- `RotateFlipOptions.angle: Double` (−180…180, default 0, applied after the 90° rotation and flips, clockwise positive) and `RotateFlipOptions.angleFill: AngleFill { case expand(background: RGBAColor) /* default, white; transparent kept when the output can hold alpha */, case cropToFit }`. `cropToFit` = the largest axis-aligned rectangle with the original aspect ratio that fits entirely inside the rotated image, centred (no empty corners). Straighten = small angle + `cropToFit` (the editor offers it as "Straighten", ±45°). Interpolation high, colour space/depth kept.
- `StepKind.perspective` ("Perspective"), `PerspectiveOptions { vertical: Double (−100…100), horizontal: Double (−100…100), auto: Bool }`: manual keystone via `CIPerspectiveTransform` (vertical +100 pulls the top edge in by 25 % of the width per side; horizontal likewise for the right edge), then crop to the largest inner rectangle with no empty areas. `auto`: `VNDetectRectanglesRequest` (min confidence 0.8, min size 0.3, max 1 result) → `CIPerspectiveCorrection` to that quad; if nothing is found the image is unchanged (and, once Task 11's notes exist, a note "No document edges found"). Auto runs before the manual sliders.
- `StepKind.trim` ("Trim"), `TrimOptions { mode: TrimMode /* .transparent (default), .color(RGBAColor), .edgeColor (colour of the top-left pixel) */, tolerance: Double (0…100, default 10; % per channel, alpha threshold for transparent), padding: Int (px kept around the content, default 0) }`. Fully trimmed (blank) image → unchanged.
- `CanvasMode.aspect(width: Double, height: Double)`: grow the canvas (never crop) to the aspect ratio, image at the anchor (centre default).
- [ ] Tests: `testAngle0IsIdentity`, `testAngle45ExpandSize` (100×100 → 142×142), `testCropToFitHasNoEmptyCorners` (rotate a solid red opaque image 10° with cropToFit; all four corners red, aspect equals original ±1 px), `testPerspectiveZeroIsIdentity`, `testPerspectiveVerticalKeepsNoTransparentCorners`, `testAutoPerspectiveFindsRectangle` (draw a white quadrilateral on black, auto → output aspect close to the drawn rectangle's; `XCTSkip` if Vision is unavailable), `testTrimTransparentBorders` (100×100 with content at 20…79 → 60×60), `testTrimEdgeColorWithTolerance`, `testTrimPadding`, `testTrimBlankUnchanged`, `testCanvasAspectSquare` (300×200 → 300×300 centred), `testOldRotateFlipJSONDecodes`.
- [ ] Implement, commit `feat(core): arbitrary rotation and straighten, perspective correction, trim, canvas aspect`.

### Task 17: Geometry editors

**Files:** `StepEditors.swift` (or new `GeometryEditors.swift`), `AppModel.swift` if `StepKind` defaults need it
- Rotate/flip editor: 90° buttons as now; "Angle" slider (−45…45 with a number field accepting −180…180) and an "Fill corners / Crop to fit (straighten)" picker; flip toggles labelled "Mirror (flip horizontally)" and "Flip vertically".
- New "Perspective" and "Trim" steps in "+ Add step" with editors (sliders with value text; Auto toggle with help "Finds a document or screen and squares it up"; Trim mode picker with colour well for `.color`).
- Canvas editor: add "Aspect ratio" mode with the aspect preset menu from Task 14 (`SizePresets.aspectRatios`).
- [ ] Build/test/lint, screenshots (with `-debugAddFiles`), commit `feat(app): editors for angle, straighten, perspective, trim and canvas aspect`.

## Metadata round (Johan, 2026-11-13)

Already present: remove all / location / camera details; set artist, copyright, description (EXIF/TIFF/IPTC/PNG mirrors).

### Task 18: Metadata editing model (Core)

**Files:** Modify `Sources/ImageconverterCore/FileSteps.swift` (`MetadataOptions`), `MetadataOps.swift`, `ImageEncoder.swift` (write XMP through `CGImageDestinationAddImageAndMetadata` when needed), `FileCommitter.swift` caller in `BatchRunner.swift` (file dates after commit), `StepSummary.swift`; Create `Sources/ImageconverterCore/MetadataFields.swift`; Tests `MetadataOpsTests.swift`, `MetadataFieldsTests.swift`

**Interfaces / rules** (old JSON keeps decoding; every new field defaults to "leave as is"):
- New `MetadataOptions` fields: `title: String?`; `keywords: [String]?` with `keywordsMode: KeywordsMode { add, replace }` (written to IPTC Keywords and XMP `dc:subject`, de-duplicated case-insensitively, each ≤ 64 chars, ≤ 64 keywords); `location: LocationEdit { keep, remove, set(latitude: Double, longitude: Double, altitude: Double?) }` replacing `removeLocation` (decode old `removeLocation: true` as `.remove`; validate −90…90 / −180…180, written as EXIF GPS with Ref letters and XMP exif:GPS*); `dateTaken: DateEdit { keep, set(Date), shift(seconds: Int) }` applied to EXIF DateTimeOriginal/DateTimeDigitized (+ OffsetTime* untouched), TIFF DateTime, IPTC DateCreated/TimeCreated, XMP xmp:CreateDate/photoshop:DateCreated; `shift` on a file with no date leaves it without one; `setFileDates: Bool` (after the file is written, set its creation and modification date to the resulting date taken, or keep the source's dates when there is none); `custom: [MetadataField]`.
- `MetadataField { namespace: MetadataNamespace /* exif, iptc, xmp */, key: String, value: String }`. `MetadataFields.writable` is the allowlist the editor offers and the decoder accepts (unknown keys are dropped on decode): EXIF — ImageDescription, Artist, Copyright, Software, Make, Model, LensModel, UserComment, BodySerialNumber (as TIFF/EXIF dictionary keys); IPTC — ObjectName, Headline, Byline, BylineTitle, Credit, Source, CopyrightNotice, CaptionAbstract, City, SubLocation, ProvinceState, CountryName, CountryCode, Writer, SpecialInstructions, OriginalTransmissionReference; XMP — dc:title, dc:creator, dc:description, dc:rights, photoshop:Headline, photoshop:City, photoshop:Country, photoshop:Credit, photoshop:Source, photoshop:Instructions, xmpRights:UsageTerms, xmpRights:WebStatement, Iptc4xmpCore:Location, Iptc4xmpCore:CountryCode. Values: control characters removed, ≤ 2000 chars. Writing XMP: build `CGImageMutableMetadata` from the source metadata, apply removals consistently with the existing strip rules (stripping "all" also clears XMP; "location" also clears XMP GPS), set values with `CGImageMetadataSetValueWithPath` (register namespaces if needed), and encode with `CGImageDestinationAddImageAndMetadata`; PNG/GIF/BMP that can't hold a namespace just skip it.
- Order: strip first, then set (as today).

- Removal additions (Johan, 2026-11-13 second list): `removeAuthor: Bool` (EXIF/TIFF Artist, IPTC Byline/BylineTitle/Writer, XMP dc:creator, PNG Author), `removeThumbnail: Bool` (no embedded EXIF/JFIF thumbnail; pass `kCGImageDestinationEmbedThumbnail: false` and drop thumbnail dictionaries), `removeIPTC: Bool` (whole IPTC dictionary and XMP Iptc4xmpCore/photoshop namespaces), `removeXMP: Bool` (write no XMP packet at all; fields we *set* still go to EXIF/IPTC), `keepWhenRemovingAll: Set<KeepField>` with `KeepField { copyright, author, dateTaken, orientation, colorProfile, cameraInfo, location }` — with `removeAll` on, these fields survive (colour profile and orientation are never metadata-stripped in a way that changes pixels; document what each means). Removals run before sets. Tests: `testRemoveAuthorEverywhere`, `testRemoveThumbnail`, `testRemoveIPTCOnly`, `testRemoveXMPOnly`, `testRemoveAllKeepsCopyrightAndDate`.
- Metadata-removal presets = metadata templates (Task 19): a template stores the removal settings too, and Task 19 ships built-in templates "Privacy (remove location, camera, author)", "Web (remove all, keep copyright)", "Remove everything".
- [ ] Tests (re-read the written file every time): `testSetTitleAndKeywordsAddAndReplace`, `testKeywordsDeduplicated`, `testSetGPSWritesRefs` (−33.86, 151.21 → S/E), `testInvalidGPSRejectedOnDecode`, `testDateSetAndShift` (+3600 s), `testShiftWithoutDateLeavesNone`, `testFileDatesFollowDateTaken`, `testCustomIPTCAndXMPFieldsWritten`, `testUnknownCustomKeyDroppedOnDecode`, `testRemoveAllAlsoClearsXMP`, `testOldMetadataJSONDecodes` (removeLocation true → `.remove`).
- [ ] Implement, commit `feat(core): edit title, keywords, dates, GPS and EXIF/IPTC/XMP fields`.

### Task 19: Metadata templates (Core)

**Files:** Create `Sources/ImageconverterCore/MetadataTemplates.swift`; Test `MetadataTemplatesTests.swift`
- `MetadataTemplate { id: UUID, name: String, options: MetadataOptions, schemaVersion: 1 }`, stored one per file in `~/Library/Application Support/imageconverter/metadata-templates/<UUID>.json`, loaded and validated with the **same hardening as PresetStore** (reuse its file-reading helper: O_NOFOLLOW/O_NONBLOCK, fstat regular file, ≤ 1 MB, name folding and uniqueness, skip reasons). `MetadataTemplateStore` with `load()`, `save(_:)`, `delete(_:)`, injected directory for tests. `apply(template, to options) -> MetadataOptions`: fields the template sets override; fields it leaves as "keep" stay as they are; `isEnabled` becomes true.
- [ ] Tests: round trip, rejection of oversized/symlink/garbage files, `testApplyMergesOnlySetFields`. Commit `feat(core): metadata templates`.

### Task 20: Metadata editor UI

**Files:** `Sources/Imageconverter/FileStepEditors.swift` (move the metadata editor to `MetadataEditor.swift`), `AppModel.swift` (template store)
- Sections inside the Metadata row (compact, collapsible groups): "Remove" (all, location, camera, author, thumbnail, IPTC, XMP; with "all" on, a "Keep" checklist of the `KeepField`s), "Describe" (Title, Artist/Author, Copyright with a "©" insert button, Description, Keywords as a token field with Add/Replace picker), "Date" (Keep / Set (date+time picker) / Shift (± days, hours, minutes)), "Set file dates to date taken" toggle, "Location" (Keep / Remove / Set: latitude, longitude, optional altitude fields with validation text), "More fields" (list of custom rows: namespace + key picker from the allowlist + value, add/remove), "Templates" menu (Apply ▸ names, Save as template…, Delete ▸ names) — Save asks for a name in a sheet like Save as preset.
- [ ] Build/test/lint, screenshots, docs (README metadata section: every field, the allowlist idea, templates), commit `feat(app): metadata editor with dates, GPS, keywords, custom fields and templates`.

## Watermark round (Johan, 2026-11-13)

Already present: text and image watermarks, opacity, 9-point position, margin, font, size (% of the shorter side), colour; image watermarks loaded once per batch (WatermarkAssets).

### Task 21: Watermark model additions (Core)

**Files:** Modify `Sources/ImageconverterCore/Watermark.swift`, `WatermarkAssets.swift`, `ImageOps.swift` (watermark drawing), `BatchRunner.swift`/`PreviewRenderer.swift` (pass the per-item token context); Create `Sources/ImageconverterCore/WatermarkText.swift`, `Sources/ImageconverterCore/SVGRasterizer.swift`; Tests `WatermarkModelTests.swift`, `WatermarkRenderTests.swift`, `WatermarkTextTests.swift`, `SVGRasterizerTests.swift`

**Interfaces / rules** (old JSON keeps decoding; new fields default to today's look):
- `WatermarkOptions.rotation: Double` (−180…180°, default 0) — rotates the mark about its centre; placement uses the rotated bounding box so margins still hold.
- `WatermarkOptions.layout: WatermarkLayout { single /* default: anchor + margin as now */, tiled(spacing: Double /* % of the mark's size, 0…400, default 100 */, stagger: Bool /* default true */) }` — tiled covers the whole image with the (rotated) mark, grid centred, anchor/margin ignored.
- Text style: `TextWatermark.shadow: WatermarkShadow? { color: RGBAColor, blur: Double /* % of line height 0…50 */, offset: Double /* % 0…50, down-right */ }`, `TextWatermark.outline: WatermarkOutline? { color: RGBAColor, width: Double /* % of line height 0…20 */ }` (stroke drawn under the fill). Image watermarks get the same optional shadow.
- Dynamic text: `WatermarkText.render(_ template: String, context: WatermarkTextContext) -> String` with tokens `{filename}` (source name without extension), `{filename.ext}`, `{date}` (date taken, else file creation date, `yyyy-MM-dd`), `{date:FORMAT}` (same safe date-format subset as the rename tokens), `{year}`, `{copyright}` (the Metadata step's copyright value if it sets one, else the source's EXIF/IPTC copyright, else empty), `{artist}` likewise. Unknown tokens stay literal. Output: control/bidi characters removed, newlines → spaces (as now), ≤ 200 chars. Context built per item from the header already read (no extra full decode).
- SVG: `ImageWatermark` accepts `.svg` files. `SVGRasterizer.rasterize(url:maxPixels:) throws -> CGImage` renders with `NSImage`/`NSSVGImageRep` at the size needed (long side ≤ 4096 px) — SVG is untrusted input: refuse files > 1 MB, refuse content containing `<script`, `<foreignObject`, `xlink:href="http`, `href="http`, `url(http`, or `@import` (case-insensitive) with the reason "This SVG can't be used (it loads external content or runs scripts)"; never fetch anything. If `NSImage` can't render SVG on this macOS, the format is unsupported with a clear message (test with `XCTSkip`).
- Templates: generalise Task 19's store into `TemplateStore<Payload: Codable & Sendable>` (folder name per kind: `metadata-templates`, `watermark-templates`), same hardening; `WatermarkTemplate { id, name, options: WatermarkOptions, schemaVersion: 1 }`. Image paths inside templates are stored like presets do (plain path now; security-scoped bookmarks arrive with milestone 6). Built-ins: "© corner (bottom right, 4 %)", "Tiled diagonal (30°, 15 % opacity)", "Filename + date (bottom left)".
- [ ] Tests: `testRotationKeepsMarginForRotatedBox`, `testTiledCoversCorners` (opaque red mark tiled on white: all four corner regions contain red), `testShadowAndOutlineDrawn` (pixels outside the glyph fill are coloured), `testTokens` ({filename}, {date:yyyy}, {copyright} from Metadata step and from source, unknown literal), `testSVGRasterizes` (simple rect SVG → expected colour; skip if unsupported), `testSVGWithExternalHrefRejected`, `testSVGOver1MBRejected`, `testOldWatermarkJSONDecodes`, template store tests via the generic store.
- [ ] Implement, commit `feat(core): watermark rotation, tiling, shadow and outline, dynamic text, SVG, templates`.

### Task 22: Watermark editor additions

**Files:** `Sources/Imageconverter/WatermarkEditor.swift` (split if > ~300 lines)
- Add: Rotation slider (−180…180, value text, quick 0/−45/45/90 buttons), Layout picker Single/Tiled (Tiled: spacing slider, stagger toggle; anchor grid and margin disabled), text Shadow and Outline toggles each revealing colour well + sliders, a token "Insert" menu next to the text field ({filename}, {date}, {year}, {copyright}, {artist}) with the live text shown for the selected image, the image chooser accepts SVG, and a "Templates" menu (Apply ▸, Save as template…, Delete ▸) like the metadata one.
- [ ] Build/test/lint, screenshots with `-debugAddFiles`, docs (README watermark section: every option and token), commit `feat(app): watermark rotation, tiling, shadow/outline, tokens, SVG and templates in the editor`.

## Rename round (Johan, 2026-11-13)

Already present: templates with tokens `{name} {ext} {date:…} {time:…} {camera} {make} {lens} {iso} {width} {height} {format} {folder} {counter:000}`, counter start, find/replace (plain/regex), sanitising.

### Task 23: Rename options: prefix/suffix, cleanup, case, more EXIF tokens (Core)

**Files:** `FileSteps.swift` (`RenameOptions`), `RenameTemplate.swift` (tokens + render pipeline), `RenameExample.swift`, `StepSummary.swift`; Create `Sources/ImageconverterCore/NameTransforms.swift`; Tests `NameTransformsTests.swift`, `RenameTemplateTests.swift`
- New `RenameOptions` fields (lenient decode, defaults = no change): `prefix: String` (""), `suffix: String` (""), `removeSpaces: Bool` (false), `specialCharacters: SpecialCharacters { keep, replace /* everything outside letters, digits, `-`, `_`, `.` becomes `replacement` */, remove }` (keep), `replacement: String` ("-" ; only `-`, `_`, `.` or "" allowed), `caseStyle: CaseStyle { keep, lower, upper, camel /* "my photo 01" → "myPhoto01" */, pascal, snake /* my_photo_01 */, kebab /* my-photo-01 */, title }` (keep).
- Render order (one function used by batch, preview and example): template render → find/replace → prefix + name + suffix → remove spaces → special characters (collapse runs of the replacement, trim it from the ends) → case style (camel/pascal/snake/kebab split words on spaces, `-`, `_`, `.` and lower→upper boundaries; digits stay attached) → the existing sanitising and fallback. Letters with diacritics count as letters (keep `å` in `keep`/case modes; `replace` keeps Unicode letters too, only symbols/punctuation are replaced).
- New tokens: `{focal}` (e.g. `24mm`, from FocalLength, rounded), `{aperture}` (`f2.8`), `{shutter}` (`1-250s` — no `/`), `{datetime}` (= `{date:yyyy-MM-dd}_{time:HHmmss}`), `{seq}` alias of `{counter}`; add them to `tokenExamples` and the header requirement check.
- [ ] Tests: each transform and the order (`testCamelCase`, `testSnakeKebabTitlePascal`, `testRemoveSpaces`, `testReplaceSpecialCharactersCollapsesAndTrims`, `testRemoveSpecialKeepsUnicodeLetters`, `testPrefixSuffixApplied`, `testOrderFindReplaceBeforeCase`), `testExifTokens` (fixture with FocalLength 24, FNumber 2.8, ExposureTime 0.004 → `24mm f2.8 1-250s`), `testOldRenameJSONDecodes`.
- [ ] Implement, commit `feat(core): rename prefix/suffix, space and character cleanup, case styles, more EXIF tokens`.

### Task 24: Rename editor additions

**Files:** `Sources/Imageconverter/FileStepEditors.swift` (move the rename editor to `RenameEditor.swift` if large)
- Add Prefix and Suffix fields, "Remove spaces" toggle, "Special characters" picker (Keep / Replace with [ - _ . ] / Remove), "Case" picker (Keep, lowercase, UPPERCASE, camelCase, PascalCase, snake_case, kebab-case, Title Case), and quick pattern presets in the Insert menu: "Date + counter" (`{date:yyyy-MM-dd}_{counter:000}`), "Camera + date" (`{camera}_{datetime}`), "Name + size" (`{name}_{width}x{height}`). The live example shows the effect of every option.
- [ ] Build/test/lint, screenshot, README rename section (every option and token), commit `feat(app): rename editor with prefix/suffix, cleanup and case options`.

## Conditional processing (Johan, 2026-11-13)

Examples from Johan: larger than 4000 px → resize to 2048; PNG with transparency → keep PNG; JPEG → another format (WebP isn't writable, see the compression round); has GPS → remove it; smaller than 500 KB → leave untouched; portrait → different resize; landscape → different output configuration.

### Task 25: Conditions model and per-item resolution (Core)

**Files:** Create `Sources/ImageconverterCore/Conditions.swift`, `Sources/ImageconverterCore/ItemFacts.swift`; Modify `Pipeline.swift` (`StepKind.condition`, operation case), `BatchRunner.swift`, `OutputPlanner.swift` (per-item format/extension), `PreviewRenderer.swift`, `SizeEstimator.swift`, `RenameRendering.swift`, `StepSummary.swift`, `Presets.swift` validation; Tests `ConditionsTests.swift`, `ConditionalBatchTests.swift`

**Interfaces / rules:**
- `ItemFacts { width: Int, height: Int /* upright */, fileSize: Int, format: OutputFormat? /* source type mapped, nil if not writable */, sourceType: String /* UTI */, hasAlpha: Bool /* header says alpha; plus, for PNG/TIFF/HEIC with alpha, a cheap downsampled (≤ 256 px) scan for any non-opaque pixel */, hasGPS: Bool, make: String?, model: String? }`, `ItemFacts.read(_ url: URL) -> ItemFacts?` (header-only except the small alpha scan).
- `Condition` cases: `.longestEdge(Comparison, Int)`, `.width(Comparison, Int)`, `.height(Comparison, Int)`, `.fileSize(Comparison, bytes: Int)`, `.format(OutputFormat or source UTI)`, `.hasTransparency(Bool)`, `.orientation(Orientation { portrait, landscape, square })`, `.hasGPS(Bool)`, `.camera(contains: String)` (case-insensitive, make or model); `Comparison { greaterThan, lessThan, atLeast, atMost }`.
- `ConditionalStep { match: Match { all, any }, conditions: [Condition] (1…10), then: [ConditionalAction], otherwise: [ConditionalAction] }`; `ConditionalAction` = `.step(PipelineStep)` (any image step except another condition: no nesting), `.output(OutputSettings)` (overrides the pipeline's output for this item), `.metadata(MetadataOptions)` (overrides the Metadata step for this item, enabled), `.rename(RenameOptions)`, `.copyOriginal` (write the source bytes unchanged to the planned destination with the source's own extension; no decode), `.skip` (write nothing; reported as "Skipped by a condition", not as a failure).
- `Pipeline.resolved(for facts: ItemFacts) -> ResolvedPipeline` (`pipeline: Pipeline` with condition steps replaced in place by the chosen branch's steps, overrides applied, plus `disposition: { process, copyOriginal, skip }`). Conditions are evaluated against the **source file's facts**, not the image part-way through the pipeline (documented in README). Multiple condition steps: evaluated in order; later overrides win; `skip`/`copyOriginal` win over process.
- BatchRunner: read facts and resolve per item before planning (cancellable); `OutputPlanner` takes per-item formats (copyOriginal uses the source extension; overwrite with copyOriginal = no-op success). `peakPixels`, the rename counter (skipped items don't consume a number), the preview (resolved for the selected item; preview shows "Skipped by a condition" / "Copied unchanged"), and `SizeEstimator` all use the resolved pipeline. Report: written / skipped-by-condition / failed counts.
- Presets: condition steps round-trip; invalid conditions (bad ranges, >10 conditions, nested condition) are rejected/dropped on decode with the existing lenient rules.
- [ ] Tests: `testLongestEdgeResize` (5000 px → 2048; 3000 px untouched), `testPNGWithTransparencyKeepsPNG` (output override PNG when alpha, else JPEG), `testJPEGToOtherFormat`, `testHasGPSRemovesLocation`, `testSmallFileCopiedUnchanged` (bytes identical), `testSkipWritesNothingAndCountsSkipped`, `testPortraitVsLandscape`, `testAnyVsAll`, `testNoNestingOnDecode`, `testPreviewAndEstimateUseResolvedPipeline`, `testCounterSkipsSkippedItems`.
- [ ] Implement, commit `feat(core): conditional steps (if/then/else) resolved per image`.

### Task 26: Condition editor

**Files:** Create `Sources/Imageconverter/ConditionEditor.swift`; Modify `PipelineSection.swift` (“+ Add step” › "If … then … else"), `StepEditors.swift` routing
- A condition row in the pipeline shows a one-line summary ("If longest edge > 4000 px → Resize 2048 · else nothing"). Expanded: "Match [all|any] of:" with condition rows (picker for the kind, comparison picker, value field with unit — px, KB/MB —, format picker, yes/no), add/remove buttons; a "Then" and an "Else" list, each with its own "+ Add" menu (image steps, Set output…, Set metadata…, Set rename…, Copy original unchanged, Skip file) and inline editors reusing the existing step editors; actions reorderable by drag like steps. Keyboard/VoiceOver complete. The preview for the selected image shows which branch applies ("Then branch" / "Else branch" chip).
- [ ] Build/test/lint, screenshots with `-debugAddFiles` (one portrait, one landscape), README how-to "Process images differently by size, format or orientation" with Johan's examples, commit `feat(app): if/then/else condition steps in the pipeline`.

## Preview round (Johan, 2026-11-13)

Already present: before/after side by side, synced pinch zoom/pan, Zoom to Fit ⌘0, Actual Size ⌥⌘0 (100 %), Original | Result table (name, folder, dimensions, size), size estimate, filmstrip. Savings % arrives with Task 12.

### Task 27: Difference image and quality ladder (Core)

**Files:** Create `Sources/ImageconverterCore/ImageDifference.swift`, `Sources/ImageconverterCore/QualityLadder.swift`; Tests `ImageDifferenceTests.swift`, `QualityLadderTests.swift`
- `ImageDifference.render(before: CGImage, after: CGImage, amplify: Double = 4) -> CGImage?`: nil when the pixel sizes differ; else an sRGB 8-bit image where each pixel is the per-channel absolute difference × amplify, clamped, on black (identical = black); plus `ImageDifference.stats(before:after:) -> (meanAbsError: Double, maxError: Int, psnr: Double)` (PSNR in dB, ∞ for identical).
- `QualityLadder.render(item: InputItem, pipeline: Pipeline, qualities: [Double] = [0.4, 0.6, 0.8, 0.95], maxPixels:) throws -> [(quality: Double, bytes: Int, image: CGImage)]` — one pipeline apply, then one encode+decode per quality (reuses the shared encode function), only for formats with `supportsQuality`.
- [ ] Tests: `testIdenticalIsBlackAndInfinitePSNR`, `testDifferentSizesNil`, `testAmplifiedDifference`, `testLadderSizesIncreaseWithQuality`, `testLadderUnsupportedFormatThrowsOrEmpty`.
- [ ] Commit `feat(core): difference image, PSNR and quality ladder`.

### Task 28: Comparison modes, checkerboard, grid/list browser, quality compare (app)

**Files:** `PreviewPane.swift`, `ZoomableComparison.swift`, `Filmstrip.swift` (→ `BatchBrowser.swift` with three modes), `AppModel+Preview.swift`, `ImageconverterApp.swift` (View menu)
- A segmented "Compare" control in the preview header: **Side by side** (current), **Split** (one image; a draggable vertical divider wipes between Before (left) and After (right); divider position persisted; works with zoom/pan), **Difference** (the amplified difference image with a PSNR/mean-error line; "Not available: the size changes" when sizes differ), **Single** (large preview of After; hold Space or press B to show Before while held / toggled, labelled). All modes share the zoom state. View menu items with ⌘1…⌘4.
- Checkerboard behind images wherever an image is drawn (preview, zoom, thumbnails), light/dark aware, 8 pt squares, so transparency is visible.
- Batch browser below the preview with a picker: **Filmstrip** (current), **Grid** (adaptive thumbnail grid in a resizable area, selection, arrow keys in 2D), **List** (Table: name, dimensions, file size, estimated output size when known — computed lazily only for visible rows' selected item, otherwise "—" —, status after a run: written/skipped/failed). Mode persisted in UserDefaults.
- "Compare quality…" button (formats with quality only) opens a panel below the images: four tiles at qualities 40/60/80/95 % showing the same zoomed region (shares the zoom state) with size and saving %; clicking a tile sets the Output quality to it. Rendered off the main actor, cancelled when the selection or pipeline changes.
- [ ] Build/test/lint, screenshots of each mode with `-debugAddFiles` (one image with transparency), README (preview section), commit `feat(app): split, difference and single comparison, checkerboard, grid and list views, quality compare`.

## Automation round (Johan, 2026-11-13; SwiftPM only: no App Intents/Share/Finder extensions; Shortcuts via the CLI)

Example to support end to end: watched folder "Incoming Images" → resize 2048 px → convert (AVIF/JPEG; WebP isn't writable) → remove GPS → quality 85 % → save to "Processed Images" → write a report, with no manual steps.

### Task 29: Jobs, folder watching, schedules, reports (Core)

**Files:** Create `Sources/ImageconverterCore/Jobs.swift` (model + store), `FolderWatcher.swift`, `JobRunner.swift`, `ProcessingReport.swift`; Tests `JobsTests.swift`, `FolderWatcherTests.swift`, `JobRunnerTests.swift`, `ProcessingReportTests.swift`
- `Job { id: UUID, name: String, pipeline: Pipeline /* a copy, or */ presetID: UUID?, inputs: [URL] (folders), recursive: Bool, output: OutputMode, trigger: JobTrigger { manual, watch, schedule(every: TimeInterval /* ≥ 300 s */) }, report: ReportFormat? { csv, json, text } , isEnabled: Bool, schemaVersion: 1 }`, stored via the generic `TemplateStore` (Task 19/21) in `jobs/`. When `presetID` is set, the preset's current pipeline is used at run time (preset automation); else the job's own pipeline (job template / export profile).
- Processed-file ledger per job (`jobs/<id>.ledger.json`, capped at 100 000 entries, oldest dropped): key = path + size + modification date; a file is processed once unless it changes. Output folders inside an input folder are excluded from watching (no loops); files the job wrote are never inputs.
- `FolderWatcher` (FSEventStream, file-level events, 1 s latency) emits candidate files; a file is ready when its size and modification date are unchanged for 2 s and it's readable (partially copied files wait). Hidden files and `.imageconverter-*.tmp` are ignored.
- `JobRunner.run(job, files:) async -> BatchReport` = `InputCollector` + `BatchRunner` + ledger update + report file written to the output folder as `imageconverter-report-<yyyy-MM-dd_HHmmss>.<ext>` (columns: source, destination, status, input bytes, output bytes, saving %, note/reason) plus totals.
- [ ] Tests: `testJobRoundTrip`, `testLedgerSkipsUnchangedAndRedoesChanged`, `testWatcherIgnoresTempAndHidden`, `testFileReadyAfterStable` (inject a clock), `testOutputInsideInputExcluded`, `testReportCSVColumnsAndTotals`, `testPresetLinkedJobUsesCurrentPreset`, the example job end to end in a temp dir (drop 2 files → processed outputs + report; GPS removed; ≤ 2048 px).
- [ ] Commit `feat(core): jobs with folder watching, schedules, ledgers and reports`.

### Task 30: Command-line tool

**Files:** `Package.swift` (new executable target `imageconverter-cli`, product name `imageconverter`), `Sources/ImageconverterCLI/main.swift` (+ small files), Tests `Tests/ImageconverterCLITests/` (argument parsing as a pure function in Core or a small library target)
- No third-party argument parser: a small hand-written parser. Commands: `imageconverter convert <files/folders…> [--preset NAME | --pipeline FILE.json] [--out DIR | --same-folder [--suffix S] | --overwrite --yes] [--format jpeg|png|heic|avif|tiff|…] [--quality 0-100] [--max-size 500KB] [--resize-long PX] [--strip-gps] [--strip-all] [--report csv|json|text] [--dry-run] [--quiet|--json]`; `imageconverter presets list`; `imageconverter jobs list|run NAME`; `imageconverter --version` (from the same version source as the app) and `--help`. Overrides apply on top of the preset/pipeline. Exit codes: 0 all ok, 1 some files failed, 2 usage error, 3 nothing to do. `--overwrite` without `--yes` refuses. Progress to stderr, results to stdout (`--json` = machine readable for Shortcuts). Pipeline JSON files are validated like presets (size cap, schema).
- README section "Command line and Shortcuts" with a Shortcuts "Run Shell Script" example.
- [ ] Tests: parser cases incl. errors, `--dry-run` writes nothing, end-to-end convert in a temp dir via the library entry point. Commit `feat: imageconverter command-line tool`.

### Task 31: Jobs UI and background running (app)

**Files:** Create `Sources/Imageconverter/JobsView.swift`, `AppModel+Jobs.swift`; Modify `ImageconverterApp.swift`
- A "Jobs" window (Window menu, ⌘J): list (name, trigger, inputs, last run, status), "New job from current pipeline", edit sheet (name, preset link or own pipeline, input folders with add/remove, recursive, output mode reusing the Save to control, trigger Manual/Watch/Every N minutes/hours, report format, enabled), Run now, open last report, reveal output.
- Watching/schedules run while the app is running. Setting "Keep running in the menu bar when the window is closed" (default off): a `MenuBarExtra` with job status, pause all, open window, quit. Notifications (UserNotifications, ask permission on first enable) when a watched job processes files or fails.
- [ ] Build/test/lint, screenshots, README how-to "Process a folder automatically", commit `feat(app): jobs window, folder watching and schedules, menu bar mode`.

### Task 32: Finder Quick Action (Services), AppleScript, URL scheme

**Files:** Create `Sources/Imageconverter/ServicesProvider.swift`, `Sources/Imageconverter/Scripting.swift`, `Resources/imageconverter.sdef` (copied into the bundle by milestone 6's release script; document), `Sources/Imageconverter/URLActions.swift`; `Info.plist` fragments documented for milestone 6 (`NSServices`, `NSAppleScriptEnabled`, `OSAScriptingDefinition`, `CFBundleURLTypes`).
- Services: "Convert with imageconverter" (adds the selected files and shows the window) and "Convert with Preset ▸ <name>" for up to 5 pinned presets (runs immediately with the global output mode; overwrite mode always asks first).
- AppleScript: `convert {alias…} using preset "Name" [to folder alias]` → list of output files; `add files {…}`; `run`; `presets` (names). Cocoa scripting via `NSScriptCommand` subclasses.
- URL scheme `imageconverter://`: `open`, `preset?name=…` (selects a preset), `add?path=…` (adds files; paths must exist and be readable), `jobs/run?name=…`. URLs are untrusted (any web page can open them): never start a conversion, write or overwrite without an in-app confirmation sheet naming what will happen; reject unknown hosts/params; cap lengths.
- Verification of Services/AppleScript/URL registration happens in milestone 6 with the real bundle; here unit-test the URL parser and the script command logic.
- [ ] Commit `feat(app): Finder quick action via Services, AppleScript commands and URL scheme`.

## Performance round (Johan, 2026-11-14: "performance should be a priority")

Already present: parallel batch (TaskGroup), memory-weighted scheduling (`WorkWindow`, peak pixels), NSCache thumbnails, header-only reads, 250 MP guard, cancellation, overall progress, preview cache rules.

### Task 33: Engine: pause/resume, per-image events, adaptive workers, low-memory mode, decode-time downsampling, retry, journal, priority (Core)

**Files:** `BatchRunner.swift`, `WorkWindow.swift`, `ImageLoader.swift`, `Pipeline.swift` (a `decodeHint`), `Adjustments.swift` (+ any CI user: one shared Metal-backed `CIContext`); Create `Sources/ImageconverterCore/BatchControl.swift`, `Sources/ImageconverterCore/RunJournal.swift`, `Sources/ImageconverterCore/SharedCIContext.swift`; Tests `BatchControlTests.swift`, `RunJournalTests.swift`, `ImageLoaderTests.swift`, `BatchRunnerTests.swift`
- `BatchControl` (actor or lock-protected class passed to `BatchRunner.run`): `pause()`, `resume()`, `isPaused`, `prioritize(_ sources: [URL])` (moves not-yet-started items to the front), `setLowMemory(Bool)`. Paused = no new items start; in-flight items finish (never interrupt a commit). Cancellation unchanged.
- Per-image events: `ItemEvent { index, source, stage: queued|decoding|processing|encoding|writing|done|failed(reason)|skipped, inputBytes?, outputBytes?, duration? }` delivered through a new `events:` callback (keep `progress:` for compatibility, derived from events).
- Adaptive workers: max concurrency = active cores; reduced to half when `ProcessInfo.thermalState` is `.serious`, to 1 at `.critical`; a `DispatchSource.makeMemoryPressureSource` warning halves the memory budget, critical drops to 1 worker until normal; low-memory mode = 2 workers, budget ÷ 4, no full-size caching anywhere. Re-evaluated between items.
- Decode-time downsampling: when the pipeline's first geometry-changing step is a resize that only shrinks (no crop/rotate-by-angle/perspective/trim before it, and no step before it that reads pixels at full size), decode with `CGImageSourceCreateThumbnailAtIndex` at `kCGImageSourceThumbnailMaxPixelSize` = 2 × the resize's target long edge (capped at the source size) with transform, then let the resize step finish with the chosen resampler. Results must match the non-downsampled path within a small tolerance (test with PSNR > 40 dB); metadata still comes from the original source.
- Retry: a file that fails with an out-of-memory/decoding/encoding error (not "unreadable", not "can't get under size", not a watermark error) is retried once at the end of the batch with concurrency 1 and low-memory decode; the report notes "Succeeded on retry".
- `RunJournal`: written at run start to `Application Support/imageconverter/journal.json` (sources, pipeline, output mode, completed indices, updated every ≤ 1 s / 20 items), deleted on normal finish or cancel; `RunJournal.pending()` returns an interrupted run on next launch. Also: before planning, delete stale `.imageconverter-*.tmp` files older than 1 hour in the destination folders of the run (only files matching the exact temp pattern).
- One shared Metal-backed `CIContext` (`MTLCreateSystemDefaultDevice`, fallback software; `cacheIntermediates: false`, working space linear extended sRGB) used by all Core Image steps.
- [ ] Tests: `testPauseStopsNewItemsResumeContinues`, `testPrioritizeMovesItemsForward`, `testEventsStageOrder`, `testLowMemoryLimitsConcurrency`, `testDecodeDownsampleMatchesFullPath` (PSNR > 40 dB, peak memory lower: compare decoded pixel counts), `testDownsampleNotUsedWhenCropFirst`, `testRetrySucceedsOnTransientFailure` (inject a failing-once encoder hook), `testJournalWrittenAndClearedAndRecovered`, `testStaleTempFilesRemovedOnlyByPattern`.
- [ ] Commit `perf(core): pause/resume, per-image events, adaptive workers, low-memory mode, decode-time downsampling, retry and run journal`.

### Task 34: Metrics: CPU, memory, throughput, ETA (Core)

**Files:** Create `Sources/ImageconverterCore/RunMetrics.swift`, `Sources/ImageconverterCore/ResourceSampler.swift`; Tests `RunMetricsTests.swift`
- `ResourceSampler.sample() -> (cpuPercent: Double /* this process, all cores, via task_info thread times delta */, memoryBytes: UInt64 /* phys_footprint from task_vm_info */)`.
- `RunMetrics` fed by `ItemEvent`s: images/s and megapixels/s (exponential moving average, 10 s window), elapsed, ETA = remaining source megapixels ÷ recent megapixels/s (falls back to item count before 3 items finish; nil until then), bytes in/out so far, saving %.
- [ ] Tests with an injected clock: `testETAFromPixelsThroughput`, `testETANilUntilThreeItems`, `testThroughputMovingAverage`, `testSamplerReturnsPlausibleValues`. Commit `feat(core): run metrics and resource sampling`.

### Task 35: Performance UI

**Files:** `SidebarView.swift`, `PreviewPane.swift` (progress area), `AppModel.swift`, list view from Task 28 (per-item stage), `ImageconverterApp.swift`
- Progress area: overall bar, "12 / 124 · 3.4 img/s · about 2 min left", Pause/Resume and Cancel buttons (⌘. cancel; ⌥⌘. pause/resume menu item); per-item stage shown in the list view and as a small ring on filmstrip/grid thumbnails (queued/working/done/failed).
- A "Performance" disclosure (in the progress area, also after a run): CPU %, memory, workers in use, img/s, MP/s, elapsed; sampled every 1 s while running only.
- Settings-like toggle "Low-memory mode" in the View or File menu and in the performance disclosure (persisted).
- On launch, if `RunJournal.pending()` exists: a sheet "The last batch was interrupted (37 of 124 done). Resume / Discard" (resume re-adds the pending items, pipeline and output mode; files still missing are reported).
- Preview/estimate tasks run at `.userInitiated`, batch work at `.utility` so the UI stays responsive; selected-item preview gets priority while a batch runs (the preview is no longer reset during a run when memory allows, i.e. not in low-memory mode).
- [ ] Build/test/lint, screenshots (a 30-image batch via `-debugAddFiles` with a synthetic folder), README "Performance" section, commit `feat(app): pause/resume, ETA, per-image progress, performance panel, low-memory mode, resume interrupted batches`.

## Privacy round (Johan, 2026-11-14: "make privacy a selling point")

Already by design: no network code, no telemetry, local-only processing, skip-on-error for malformed files, 250 MP pixel guard, atomic temp files removed on failure; App Sandbox without a network entitlement arrives in milestone 6.

### Task 36: Hardening and privacy scanner (Core)

**Files:** `ImageLoader.swift` (limits), `FileCommitter.swift`/`BatchRunner.swift` (temp cleanup on cancel/quit hooks), Create `Sources/ImageconverterCore/DecodeLimits.swift`, `Sources/ImageconverterCore/PrivacyScanner.swift`; Tests `DecodeLimitsTests.swift`, `PrivacyScannerTests.swift`, `NoNetworkTests.swift`
- `DecodeLimits { maxPixels = 250_000_000, maxSide = 65_535, maxDecodedBytes = min(4 GiB, physicalMemory / 4), maxFileBytes = 2 GiB, maxFrames inspected = 1 }` checked from the header **before** any pixel decode (pixels × bytes-per-pixel from the header's depth/channels × 1.5 for working copies); violations give clear reasons ("Image is too large (… px on one side)", "Would need more than … of memory to open"). Decompression-bomb heuristic: if the declared pixel count is > 50 MP and the file is < 1/1000 of the decoded size, refuse unless it is a format known to compress extremely well (PNG/GIF of flat colour is legitimate: only refuse when also > 250 MP or > maxDecodedBytes) — the hard limits are the real guard; never trust declared sizes beyond them. All readers (batch, preview, thumbnails, estimate, watermark images, SVG) go through the same checks.
- Temp files: `FileCommitter.cleanUp(in directories:)` removes only `.imageconverter-<UUID>.tmp` files (exact pattern) — called on cancel, on app quit (Task 37 hook) and at run start (stale > 1 h, as Task 33). Documented honestly: deleted, not "securely wiped" (SSDs/APFS make overwriting meaningless).
- `PrivacyScanner.scan(_ url: URL) -> PrivacyFindings` (header/metadata only, no pixel decode except the embedded thumbnail size check): findings with severity: GPS location (high), camera/lens serial numbers (`BodySerialNumber`, `LensSerialNumber`, `CameraOwnerName`, MakerNote serials where ImageIO exposes them) (high), owner/author names (Artist, Byline, dc:creator, CameraOwnerName) (medium), XMP edit history / document IDs (`xmpMM:History`, `DocumentID`, `OriginalDocumentID`) (medium), embedded thumbnail whose aspect ratio differs from the image (may show the uncropped photo) (high), capture date/time (low), software/device model (low). `PrivacyFindings.suggestedMetadataOptions` = the removal settings that clear all high/medium findings.
- `NoNetworkTests`: scan `Sources/` for networking APIs (`URLSession`, `NWConnection`, `CFSocket`, `NSURLConnection`, `WKWebView`, `http://`/`https://` string literals except in comments/README links) and fail if any appear; documents the policy.
- [ ] Tests: `testRejectsTooWideImage` (header-only fixture 70 000 × 10), `testRejectsMemoryOverLimit` (inject a small limit), `testBombHeuristic` (crafted PNG header declaring 30 000 × 30 000), `testScannerFindsGPSSerialOwnerHistoryThumbnail` (fixtures written with ImageIO), `testScannerCleanImageNoFindings`, `testSuggestedOptionsClearFindings` (apply suggestion, re-scan output → no high/medium), `testCleanupOnlyRemovesExactPattern`, `testNoNetworkAPIsInSources`.
- [ ] Commit `feat(core): decode limits, decompression-bomb guard, privacy scanner, temp cleanup, no-network test`.

### Task 37: Privacy in the app

**Files:** Create `Sources/Imageconverter/PrivacyPanel.swift`, `Sources/Imageconverter/AppDelegate.swift` (quit hook); Modify `SidebarView.swift`/`PreviewPane.swift` (badges), `ImageconverterApp.swift`, `README.md`, `SECURITY.md`
- Privacy scan: runs automatically (off the main actor, header-only, cancellable) when images are added; a shield chip in the count row ("3 images share their location") opens a panel listing findings per image (with severity colours) and a "Remove these from the output" button that turns on the Metadata step with `suggestedMetadataOptions` (merging, never weakening existing removals). The preview table gets a "Privacy" row (Original: findings summary; Result: what remains after the pipeline, using the same scanner on the estimated output's metadata).
- Quit while running: `applicationShouldTerminate` asks "A batch is running. Stop and quit?"; on confirm cancels, waits for in-flight commits (≤ 10 s), cleans temp files, then quits.
- A "Privacy" section in the About window (milestone 6 builds the window; for now a Help menu item "Privacy…" opening a small window): "Works entirely offline. No network access, no telemetry, no uploads. Built only on Apple frameworks (SwiftUI, AppKit, ImageIO, Core Graphics, Core Image, Accelerate, Vision, UniformTypeIdentifiers); no third-party code." plus the limits in force.
- README: a prominent "Privacy" section near the top (the above, the limits, what the privacy scan looks for, the honest note about temp-file deletion), SECURITY.md updated (threat model: untrusted images/SVG/presets/URL scheme input; no network).
- [ ] Build/test/lint, screenshots, commit `feat(app): privacy scan, safe quit, privacy statement`.

## Reporting round (Johan, 2026-11-14)

### Task 38: Report model, exports, error log, history (Core)

**Files:** `Sources/ImageconverterCore/ProcessingReport.swift` (from Task 12; extend), Create `Sources/ImageconverterCore/ReportExporter.swift`, `Sources/ImageconverterCore/RunHistory.swift`, `Sources/ImageconverterCore/ErrorLog.swift`; Tests `ReportExporterTests.swift`, `RunHistoryTests.swift`, `ErrorLogTests.swift`
- `RunSummary { id, startedAt, finishedAt, jobName?, presetName?, outputMode, total, succeeded, failed, skipped (by condition/unchanged), cancelled, inputBytes, outputBytes, savedBytes, averageRatio /* output/input over succeeded files */, averageDuration, totalDuration }` + `[ReportEntry { source, destination?, status, inputBytes, outputBytes?, ratio?, duration, width×height in/out, note/reason }]`.
- `ReportExporter.csv(_:)`, `.json(_:)` (stable keys, ISO 8601 dates), `.html(_:)` — a single self-contained file (inline CSS only, no scripts, no external resources, light/dark via `prefers-color-scheme`), summary cards + a table; **every string from filenames/metadata/reasons is HTML-escaped** (`& < > " '`), and CSV fields are quoted and protected against formula injection (prefix `'` when a field starts with `= + - @`, tab or CR).
- `ErrorLog`: appends one line per failure (ISO time, file path, reason) to `Application Support/imageconverter/logs/errors.log`, rotated at 1 MB (keep 3), no image data; `recent(limit:)` for the UI.
- `RunHistory`: stores each run's `RunSummary` + entries as `history/<id>.json` (entries capped at 5000 per run), keeps the latest 100 runs (oldest deleted), loads with the same hardening as presets; job runs carry `jobName` so job summaries = history filtered by job.
- [ ] Tests: `testSummaryMaths` (ratio, saved, averages), `testCSVQuotingAndFormulaInjection`, `testHTMLEscapesFilenames` (a file named `<script>alert(1)</script>.jpg` appears escaped; the HTML contains no `<script`), `testJSONRoundTrip`, `testErrorLogRotation`, `testHistoryKeeps100AndRejectsGarbage`. Commit `feat(core): run summaries, CSV/JSON/HTML exports, error log, history`.

### Task 39: Reports and history UI

**Files:** Create `Sources/Imageconverter/HistoryView.swift`, `Sources/Imageconverter/ReportView.swift`; Modify `SidebarView.swift`, `ImageconverterApp.swift`, Jobs window (Task 31)
- After a run, the sidebar "Report" section (Task 12) shows the summary cards (processed, succeeded, failed, skipped, original → output, saved, average ratio, average time) and "Export ▸ CSV / JSON / HTML…" (save panel) plus "Show error log".
- A "History" window (Window menu, ⌥⌘H): runs list (date, preset/job, counts, saved), detail = the same ReportView with per-image table (sortable), export, "Reveal outputs", delete entry, "Clear history"; a filter by job gives job summaries; the Jobs window links to them.
- [ ] Build/test/lint, screenshots, README "Reports and history", commit `feat(app): run reports with exports, error log and processing history`.
