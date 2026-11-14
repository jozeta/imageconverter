# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS app for batch image processing: the user drops images/folders, builds a pipeline
(resize, crop, rotate/flip, canvas, color profile, adjust, watermark, then metadata, rename, output format)
and runs it over the whole batch. Pipelines can be saved as presets. Reads any format ImageIO
decodes; writes JPEG/PNG/HEIC/TIFF (+ GIF/BMP/JPEG 2000 where ImageIO can). English only.
Distributed as a signed, notarized app (not the App Store).

Project type: Swift / macOS app. Created 2026-11-13. **The agreed design is
`docs/superpowers/specs/2026-11-13-imageconverter-design.md`. Read it before building anything**;
decisions in it marked "(Johan)" are the user's and must not be changed without asking.
**Keep this file up to date** as the project takes shape.

## Commands

```sh
swift run           # opens the app window (or: claude-update)
swift build
# Debug builds only, for screenshots: add images at launch, start the preview zoomed (× fit), widen the window,
# open every step's editor
.build/debug/Imageconverter -debugAddFiles /path/a.jpg /path/b.png -debugZoom 4 -debugWindowWidth 1300 -debugExpandSteps
```

Tests:

```sh
swift test
swiftlint           # if installed (brew install swiftlint)
```

## Layout

- `Package.swift`: SwiftPM manifest (macOS 14+)
- `Sources/Imageconverter/`: the SwiftUI app; `DesignSystem/LadaGlass.swift` is the copied Låda Glass file
  - `ImageconverterApp.swift` (scenes), `SidebarView.swift` (main window), `AppModel+Estimate.swift` (debounced size estimate; there is no Settings window, the Output row holds "Save to"),
    `AppModel.swift` (items, pipeline persisted as JSON under `currentPipeline`, run/cancel, toasts),
    `AppSettings.swift` (output mode, persisted in UserDefaults), `PipelineSection.swift` (step rows,
    reorder, add, fixed Output row), `StepEditors.swift` (one editor per step kind), `AdjustEditor.swift` (Adjust step sliders), `WatermarkEditor.swift` (watermark step editor, sliders, thumbnail), `StepControls.swift` (shared controls),
    `FileStepEditors.swift` (Metadata and Rename rows, Metadata editor), `RenameEditor.swift` (Rename editor; the live rename example is computed in `AppModel`),
    `PresetBar.swift` and `AppModel+Presets.swift` (preset picker, save/rename/delete),
    `PreviewPane.swift` (before/after, Original | Result table, run progress bar), `Filmstrip.swift` (thumbnails, ←/→),
    `ZoomableComparison.swift` (`ZoomController` on the model: synced zoom shared by both preview sides and the View menu; pinch/scroll/drag NSView overlay),
    `AppModel+Preview.swift` (selection, 300 ms debounced render task with a generation counter, thumbnail cache).
    `WindowSizer.swift` (applies `WindowLayout`: fixed 360 pt sidebar; preview hidden → window = sidebar content height,
    preview open → resizable, min 780 × 560, sidebar panel stretches; animated toggles via `NSAnimationContext`; the
    root view applies its ranges with `.windowResizability(.contentSize)`; full screen is off), `EdgeHandle.swift` (grab handles on the panel edges).
    `previewCollapsed` and `pipelineCollapsed` are persisted in UserDefaults
- `Sources/ImageconverterCore/`: all logic: the pipeline model, each operation as a pure function
  (`CGImage → CGImage`, metadata → metadata), rename templating, collision naming, presets
  (JSON, `schemaVersion`), the batch runner. No SwiftUI here. Files so far:
  - `OutputFormat` (formats, `OutputSettings`), `ConversionError`, `ImageLoader`, `ImageEncoder`,
    `InputCollector` (files/folders to items), `OutputPlanner` (destinations per output mode),
    `FileCommitter` (atomic writes, trash replaced originals), `BatchRunner` (parallel run, progress, cancel),
    `Pipeline` (steps, options, `apply`), `FileSteps` (`MetadataOptions`, `RenameOptions`), `MetadataOps` (metadata stripping/setting, DPI; `+XMP` builds the XMP written via `CGImageDestinationAddImageAndMetadata`, `+Keep` the remove-all keep lists; `Pipeline.outputProperties` in `Pipeline+Resize` applies both; it also has `outputDPI` and the Lanczos memory count for `peakPixels`), `MetadataEdits` (location, date, keyword and keep choices), `MetadataFields` (allowlisted custom EXIF/IPTC/XMP fields), `MetadataDates` (date set/shift),
    `RenameTemplate` (tokens, sanitising), `StepSummary` (one-line step descriptions), `Geometry` (size maths),
    `ResizeModel` (`ResizeMode`, `ResizeOptions` with resampling and DPI), `Resampler` (Lanczos via vImage, bicubic via Core Image, bilinear/nearest via Core Graphics), `SizePresets` (aspect ratios, social and resolution sizes), `ImageOps` (resize, crop, canvas, color profile), `ImageOps+Watermark` (watermark drawing: rotation, tiling, shadow, outline), `Rotation` (rotate/flip options, arbitrary angle and straighten, rotation geometry), `Perspective` (keystone + Vision auto correction via Core Image), `Trim` (border trimming), `Watermark` (options, layout, shadow/outline, placement maths), `WatermarkText` (per-item token context and rendering), `WatermarkTemplates` (watermark templates and built-ins on `TemplateStore`), `SVGRasterizer` (untrusted SVG checks, then NSImage rendering; never fetches), `Adjustments` (`AdjustOptions`, Core Image render in linear extended sRGB, output in the input's colour space and bit depth), `WatermarkAssets` (image and SVG watermarks loaded once per batch, with the failure reason), `WorkWindow` (memory-aware batch scheduling), `CompressionSearch` (quality, target size, maximum size and smart (SSIM) compression, capped encode searches), `ImageSimilarity` (luma SSIM at ≤ 1024 px), `Presets`/`PresetSession` (preset files, built-ins, unsaved-change tracking), `PreviewRenderer` (actor: before/after for one item, caches the decoded source), `ZoomMath` (`ZoomState`, zoom around an anchor, pan, clamping), `WindowLayout` (main window size rules and frame maths), `NameReplacement` (find/replace in names, plain or regex), `SizeEstimator` (encodes a full-size render for the size estimate)
- `Tests/ImageconverterCoreTests/`: tests (operations on small generated images, rename tokens,
  resize/crop maths, collisions, preset round-trip and rejection, metadata really stripped)
- `docs/superpowers/specs/`: design documents; `docs/superpowers/plans/`: implementation plans
- Planned: `scripts/release.sh` (bundle `.app`, sign with Developer ID + hardened runtime,
  notarize with a `notarytool` keychain profile, staple). Credentials stay in the keychain.

## Architecture rules

- Apple frameworks only, no third-party dependencies in v1: ImageIO (decode/encode/metadata),
  Core Graphics (pixel operations), ColorSync/`CGColorSpace` (profiles).
- App Sandbox **on**: user-selected read/write only, no network entitlement. Folder access for
  same-folder/overwrite output is requested once per folder and kept as security-scoped bookmarks.
- Never lose files: writes go to a temp file and are moved into place atomically; overwrite mode
  with a changed name/format moves the original to the Trash (`FileManager.trashItem`); existing
  unrelated files are never replaced (append `_2`, `_3`, …).
- Output mode is one global setting (not stored in presets). Warn once when overwrite is
  *selected*, never at run time.
- Image files and their metadata are untrusted: guard pixel count (default 250 MP), sanitise
  metadata used in filenames, validate preset files on load.
- Failing files are skipped and reported at the end; a run never stops for one bad file.

## Design

Låda Glass 2.2.0 (`~/Desktop/code/tools/design`, preview: `design/preview.html` there): dark frosted
glass is the main theme, light the alternative, compact density. Main window (layout "B", agreed):
a sidebar with the preset picker, a drop zone, the pipeline (steps as accordions with on/off
toggles, collapsible) and Run; on the right a collapsible before/after preview with a filmstrip. Use its `lg-` components and
tokens instead of new styles; don't edit the vendored copy (update it when `claude-check` says it's
old). UI must stay responsive (no sideways scrolling at 375 px) and keyboard accessible.

## Working agreements

- This repo follows the app standards in `~/Desktop/code/tools/standards/STANDARDS.md` (rule IDs,
  severities). `claude-check --repo .` checks it; decisions and reasoned waivers go in `.claude-standards`.
- Plan before building: agree on goals, scope and tech choices first, then implement in small,
  tested steps (failing test first).
- Never commit secrets. `.env` files are gitignored; commit only `.env.example` with placeholders.
- Untrusted data (network, files, URLs, storage, user input) is rendered with `textContent` or a
  sanitizer, never `innerHTML`; no `eval`; no third-party requests (self-host libraries in `vendor/`).
- Keep CI (`.github/workflows/ci.yml`) green; record user-visible changes under "Unreleased" in
  `CHANGELOG.md`.
- Version 0.1.0 (in `VERSION`). Show it in the app (an About page, `--version` or a footer, read
  from that file). Bump it on every push that changes the app (patch: fixes, minor: features, major:
  breaking changes), and in the same commit move "Unreleased" under the new version and update the
  README's version and "What's new".
- The README stays detailed: what it is, installation, configuration and settings, how-tos, and
  screenshots in a grid with a caption under each.
- There is no GitHub remote yet. Don't push or create repos unless asked.
