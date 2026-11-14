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
    reorder, add, fixed Output row), `StepEditors.swift` (one editor per step kind), `AdjustEditor.swift` (Adjust step sliders), `WatermarkEditor.swift` (watermark step editor) with `WatermarkControls.swift` (sliders, rotation, layout, shadow, outline), `WatermarkTemplatesMenu.swift` + `WatermarkTemplatesModel.swift` (templates menu and store, injected with `.environment`), `WatermarkThumbnail.swift` (chosen image, SVG refusal reason), `AppModel+WatermarkText.swift` (live token text), `NameSheet.swift` (name sheet for presets and templates), `StepControls.swift` (shared controls),
    `FileStepEditors.swift` (Metadata and Rename rows), `MetadataEditor.swift` + `MetadataDateEditor.swift` + `MetadataCustomFieldsEditor.swift` (Metadata editor groups), `MetadataTemplatesMenu.swift`/`MetadataTemplatesModel.swift` (templates, like the watermark ones), `RenameEditor.swift` (Rename editor; the live rename example is computed in `AppModel`),
    `ConditionEditor.swift` (if/then/else editor: match, condition rows) and `ConditionActions.swift` (Then/Else action lists reusing the step editors),
    `PresetBar.swift` and `AppModel+Presets.swift` (preset picker, save/rename/delete),
    `PreviewPane.swift` (before/after, Original | Result table, run progress bar), `ComparisonViews.swift` (side by side, split, difference, single), `QualityPanel.swift` (quality ladder tiles), `CompareController.swift` (compare and browser modes, per-selection difference and ladder) and `CompareController+Keys.swift` (Space/B monitor, only while Single mode is shown), `AppModel+Compare.swift` (difference/ladder renders, list facts), `Checkerboard.swift`, `BatchBrowser.swift` (filmstrip, grid, resizable area) and `BatchTable.swift` (list),
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
    `FileCommitter` (atomic writes, trash replaced originals), `BatchRunner` (parallel run, progress, cancel), `BatchRunner+Schedule` (the scheduler: adaptive limits, pause, priorities, end-of-batch retry, events, journal), `BatchControl` (pause/resume/prioritize/low-memory, `ItemEvent`, memory pressure, `BatchLimits`), `RunJournal` (interrupted-run journal, stale temp file cleanup), `Pipeline+DecodeHint` (when the batch may decode downsampled), `SharedCIContext` (the one Metal-backed `CIContext`),
    `Pipeline` (steps, options, `apply`), `FileSteps` (`MetadataOptions`, `RenameOptions`), `MetadataOps` (metadata stripping/setting, DPI; `+XMP` builds the XMP written via `CGImageDestinationAddImageAndMetadata`, `+Keep` the remove-all keep lists; `Pipeline.outputProperties` in `Pipeline+Resize` applies both; it also has `outputDPI` and the Lanczos memory count for `peakPixels`), `MetadataEdits` (location, date, keyword and keep choices), `MetadataFields` (allowlisted custom EXIF/IPTC/XMP fields), `MetadataDates` (date set/shift),
    `RenameTemplate` (tokens, sanitising), `StepSummary` (one-line step descriptions), `Geometry` (size maths),
    `ResizeModel` (`ResizeMode`, `ResizeOptions` with resampling and DPI), `Resampler` (Lanczos via vImage, bicubic via Core Image, bilinear/nearest via Core Graphics), `SizePresets` (aspect ratios, social and resolution sizes), `ImageOps` (resize, crop, canvas, color profile), `ImageOps+Watermark` (watermark drawing: rotation, tiling, shadow, outline), `Rotation` (rotate/flip options, arbitrary angle and straighten, rotation geometry), `Perspective` (keystone + Vision auto correction via Core Image), `Trim` (border trimming), `Watermark` (options, layout, shadow/outline, placement maths), `WatermarkText` (per-item token context and rendering), `WatermarkTemplates` (watermark templates and built-ins on `TemplateStore`), `SVGSanitizer` (untrusted SVG: strict UTF-8, XMLParser, element/attribute allowlist, re-serialised; `+Prolog`: XML declaration and the one standard doctype; `+Parser`: the validating tree builder; `+Style`: simple `<style>` rules inlined as attributes; `+References`: style values, reference cycles and `use` expansion cap), `SVGRasterizer` (size-capped read, renders only the sanitised SVG via NSImage; never fetches), `Adjustments` (`AdjustOptions`, Core Image render in linear extended sRGB, output in the input's colour space and bit depth), `WatermarkAssets` (image and SVG watermarks loaded once per batch, with the failure reason), `WorkWindow` (memory-aware batch scheduling), `CompressionSearch` (quality, target size, maximum size and smart (SSIM) compression, capped encode searches), `ImageSimilarity` (luma SSIM at ≤ 1024 px), `Presets`/`PresetSession` (preset files, built-ins, unsaved-change tracking), `PreviewRenderer` (actor: before/after for one item, caches the decoded source), `Conditions` (if/then/else model, `Pipeline.resolved(for:)` → `ResolvedPipeline` with a disposition: process, copy original, skip), `ItemFacts` (header-only facts a condition tests), `ConditionPreview` (`ItemFactsCache` actor: the preview's counter number and branch chips, facts cached per file version), `BatchRunner+Conditions` (per-item resolve, names and plans; copy original),
    `Jobs` (`Job`, `JobSettings`, `JobStore` over `TemplateStore` in `jobs/`, `JobSchedule`), `ProcessedLedger` (`jobs/<id>.ledger.json`: processed inputs with failed-attempt counts, give up after 3, and the job's outputs, each capped separately),
    `FolderWatcher` (FSEvents watcher, `ReadinessTracker` 2 s stability state machine, `WatchFilter`), `JobScheduler` (schedule timers),
    `JobRunner` (candidates → ledger and 2 s stability check → `BatchRunner` → ledger update → report file), `ProcessingReport` (run summary + entries),
    `ReportExporter` (CSV with formula-injection guard, JSON with sorted keys, text), `ZoomMath` (`ZoomState`, zoom around an anchor, pan, clamping), `WindowLayout` (main window size rules and frame maths), `NameReplacement` (find/replace in names, plain or regex), `SizeEstimator` (encodes a full-size render for the size estimate)
- `Sources/ImageconverterCLIKit/`: the command line (hand-written `CLIParser`, `CLIRunner`, `ConvertCommand`, `ListCommands`); `Sources/ImageconverterCLI/main.swift` is a thin wrapper (product `imageconverter-cli`, installed as `imageconverter`; tests in `Tests/ImageconverterCLITests/`). Core: `AppInfo.version` (kept equal to `VERSION` by a test), `PipelineFile`
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
