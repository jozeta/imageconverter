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
