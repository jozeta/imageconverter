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
scripts/release.sh       # dist/imageconverter.app + zip (ad hoc signed; --notarize needs SIGN_IDENTITY and NOTARY_PROFILE)
scripts/install-cli.sh  # links the app's command-line tool as ~/.local/bin/imageconverter
scripts/screenshots.sh  # regenerates docs/screenshots/*.png (DEBUG app, own settings suite `readme`, sample images)
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
    `ConditionEditor.swift` (if/then/else editor: match, condition rows with a Not switch), `ConditionKind.swift` (the grouped kind picker),
    `ConditionControls.swift`/`ConditionValueControls.swift` (value controls per kind: numbers, text, dates, metadata fields),
    `ConditionActions.swift` (Then/Else action lists reusing the step editors; grouped + Add menu) and `ConditionActionEditors.swift` (subfolder, tags, preset, keywords, note),
    `PresetBar.swift` and `AppModel+Presets.swift` (preset picker, save/rename/delete),
    `PreviewPane.swift` (before/after, Original | Result table, run progress bar), `ComparisonViews.swift` (side by side, split, difference, single), `QualityPanel.swift` (quality ladder tiles), `CompareController.swift` (compare and browser modes, per-selection difference and ladder) and `CompareController+Keys.swift` (Space/B monitor, only while Single mode is shown), `AppModel+Compare.swift` (difference/ladder renders, list facts), `Checkerboard.swift`, `BatchBrowser.swift` (filmstrip, grid, resizable area) and `BatchTable.swift` (list),
    `ZoomableComparison.swift` (`ZoomController` on the model: synced zoom shared by both preview sides and the View menu; pinch/scroll/drag NSView overlay),
    `AppModel+Preview.swift` (selection, 300 ms debounced render task with a generation counter, thumbnail cache).
    `WindowSizer.swift` + `WindowSizer+Height.swift` (apply `WindowLayout`: fixed 360 pt sidebar; height from the sidebar's
    measured parts: pipeline collapsed → exactly the content; expanded → user-resizable, the chosen height remembered in
    `expandedWindowHeight`, extra height as a gap above Output, steps scroll when shorter; preview open → width resizable,
    min 780; the preview width toggle animates via `NSAnimationContext`; the root view applies its ranges with
    `.windowResizability(.contentSize)`; full screen is off), `SidebarMotion.swift` (every height change: the sidebar
    animates one value, `SidebarHeightReporter` reports it per frame and the window is set to it in the same pass, so
    the edge and content move together; wrap height-changing edits in `SidebarMotion.perform` / `.sidebarAnimated`),
    `EdgeHandle.swift` (grab handles on the panel edges). DEBUG: `-debugTogglePipelineEvery <s>`, `-debugStepCycle <s>`,
    `-debugWindowHeight <pt>`.
    `RunMonitor.swift` (live stages via an ordered event stream, `RunMetrics`, 1 s `ResourceSampler` while running),
    `RunStatusViews.swift` (progress area, Performance panel, thumbnail `StageRing`, interrupted-run sheet),
    `AppModel+Performance.swift` (pause, Process Next, low-memory mode, run journal path and resume).
    `ReportView.swift` (summary cards, export menu, per-file table, error log sheet), `HistoryView.swift` (History window, `HistoryController`), `AppModel+History.swift` (manual runs recorded once; jobs record in `JobsController.record`).
    `PrivacyPanel.swift` (shield chip, panel, Help ▸ Privacy… window) and `AppModel+Privacy.swift` (scan task, `PrivacyState`); `QuitCoordinator.swift` (⌘Q while running).
    `AccessStore.swift` (sandbox folder grants: `folderGrants` bookmarks, session roots, `ensureAccess` before every
    `startRun` with pre-filled open panels; only when `Sandbox.isActive`, DEBUG `-debugSimulateSandbox`) and
    `FolderAccessWindow.swift` (Help ▸ Folder Access…, with Add Folder…; Remove is refused while a batch or job runs).
    `AppSettings` keeps `outputFolderBookmark` (rebuilt whenever a folder is chosen, also the same one).
    `AppModel+Access.swift` (refreshes stale watermark bookmarks in the edited pipeline), `AppModel+ClearAll.swift`
    (More ▸ Clear All…), `AboutView.swift` (About window), `AdjustSliderControl.swift` (Adjust slider with double-click
    reset), `StepHelpHover.swift` (1.5 s hover help boxes from Core `StepHelp`), `WindowDropTarget.swift` (file drops
    anywhere in the window; `addDroppedFiles` environment action so step rows' String drop targets pass file
    locations on instead of swallowing them). `AppDefaults.swift` (the settings store; DEBUG `-debugDefaultsSuite`),
    `ResizeEditor.swift` (Resize editor), `GeometryEditors.swift` (Crop, Rotate/flip, Canvas, Perspective editors),
    `OutputRow.swift` (format, quality and compression controls of the Output row).
    `previewCollapsed` and `pipelineCollapsed` are persisted in UserDefaults
  - Jobs: `JobsController.swift` (+ `JobsController+Runs.swift`: watchers, schedules, the per-job run queue,
    background runs at half the cores, history/error log, bookmarks via `JobFolders`), `JobsView.swift` (Jobs
    window, ⌘J), `JobEditor.swift` (edit sheet), `SaveToControl.swift` (shared Save to), `JobNotifier.swift`
    (UserNotifications, only with an app bundle), `MenuBarContent.swift` (menu bar mode), `AppModel+Jobs.swift`,
    `QuitCoordinator.swift` (`applicationShouldTerminate`: asks, stops batch and job runs, waits, cleans up).
    `ExternalActions.swift` (`AppDelegate`: services provider, the `kAEGetURL` link handler and the `kAEOpenDocuments`
    handler for files opened with the app (not `application(_:open:)`, which lets SwiftUI open a window per file);
    the bridge to the model, which waits at launch for the main window; confirmation sheets, background converts), `ServicesProvider.swift` (Finder services), `Scripting.swift`
    (`NSScriptCommand` subclasses named in the sdef), `URLActions.swift` (confirmed link actions);
    `AppModel+RenameExample.swift` (the Rename editor's live example, using the selected image's resolved branch)
- `Sources/ImageconverterCore/`: all logic: the pipeline model, each operation as a pure function
  (`CGImage → CGImage`, metadata → metadata), rename templating, collision naming, presets
  (JSON, `schemaVersion`), the batch runner. No SwiftUI here. Files so far:
  - `OutputFormat` (formats, `OutputSettings`), `ConversionError`, `ImageLoader`, `ImageEncoder`,
    `InputCollector` (files/folders to items), `OutputPlanner` (destinations per output mode),
    `FileCommitter` (atomic writes, trash replaced originals, temp file pattern, `cleanUp(in:)` for cancel/quit/stale temps),
    `DecodeLimits` (the one gate before any pixel decode: pixels, side, memory, file size, decompression-bomb heuristic; `ImageLoader.load`/`thumbnail` use it),
    `PrivacyScanner` (header/metadata-only privacy findings with severities and suggested `MetadataOptions`), `BatchRunner` (parallel run, progress, cancel), `BatchRunner+Schedule` (the scheduler: adaptive limits, pause, priorities, end-of-batch retry, events, journal), `BatchControl` (pause/resume/prioritize/low-memory, `ItemEvent`, memory pressure, `BatchLimits`), `RunJournal` (interrupted-run journal with a `.done` completion log appended per finished item and, in overwrite mode, per-source fingerprints so a resume skips replaced originals; bookmarks of source folders, loose source files (≤ 2 000) and the output folder, made and resolved in `RunJournal+Access`; stale temp folders), `ActiveSources` (in-process registry of files runs are working on; a held file is skipped as "Busy in another run"), `Pipeline+DecodeHint` (when the batch may decode downsampled), `SharedCIContext` (the one Metal-backed `CIContext`),
    `Pipeline` (steps, options, `apply`), `FileSteps` (`MetadataOptions`, `RenameOptions`), `MetadataOps` (metadata stripping/setting, DPI; `+XMP` builds the XMP written via `CGImageDestinationAddImageAndMetadata`, `+Keep` the remove-all keep lists; `Pipeline.outputProperties` in `Pipeline+Resize` applies both; it also has `outputDPI` and the Lanczos memory count for `peakPixels`), `MetadataEdits` (location, date, keyword and keep choices), `MetadataFields` (allowlisted custom EXIF/IPTC/XMP fields), `MetadataDates` (date set/shift), `MetadataFloor` (the Metadata step's removals as a floor for condition overrides; copies that must lose metadata are converted),
    `RenameTemplate` (tokens, sanitising), `StepSummary` (one-line step descriptions), `Geometry` (size maths),
    `ResizeModel` (`ResizeMode`, `ResizeOptions` with resampling and DPI), `Resampler` (Lanczos via vImage, bicubic via Core Image, bilinear/nearest via Core Graphics), `SizePresets` (aspect ratios, social and resolution sizes), `ImageOps` (resize, crop, canvas, color profile), `ImageOps+Watermark` (watermark drawing: rotation, tiling, shadow, outline), `Rotation` (rotate/flip options, arbitrary angle and straighten, rotation geometry), `Perspective` (keystone + Vision auto correction via Core Image), `Trim` (border trimming), `Watermark` (options, layout, shadow/outline, placement maths), `WatermarkText` (per-item token context and rendering), `WatermarkTemplates` (watermark templates and built-ins on `TemplateStore`), `SVGSanitizer` (untrusted SVG: strict UTF-8, XMLParser, element/attribute allowlist, re-serialised; `+Prolog`: XML declaration and the one standard doctype; `+Parser`: the validating tree builder; `+Style`: simple `<style>` rules inlined as attributes; `+References`: style values, reference cycles and `use` expansion cap), `SVGRasterizer` (size-capped read, renders only the sanitised SVG via NSImage; never fetches), `Adjustments` (`AdjustOptions`, Core Image render in linear extended sRGB, output in the input's colour space and bit depth), `WatermarkAssets` (image and SVG watermarks loaded once per batch, with the failure reason), `WorkWindow` (memory-aware batch scheduling), `AccessNeeds` (+ `Sandbox.isActive`: folders a run needs that aren't granted), `AccessPrompt` (the ask-for-folders loop without UI, `askToRead` for resume, and `FolderGrantList`), `ResumePlan` (what resuming an interrupted batch runs; readability, not existence, decides; `PausableClock`), `DropPayload` (file locations in a text drop), `ItemFacts+Metadata` (metadata facts for conditions), `ResettableSlider` (double-click reset maths), `StepHelp` (hover-help texts per step), `ImageWatermark` (path + bookmark), `CompressionSearch` (quality, target size, maximum size and smart (SSIM) compression, capped encode searches), `ImageSimilarity` (luma SSIM at ≤ 1024 px), `Presets`/`PresetSession` (preset files, built-ins, unsaved-change tracking), `PreviewRenderer` (actor: before/after for one item, caches the decoded source), `PrivacyScanner`/`PrivacyCache`/`PrivacySummary`/`PrivacyStatement` (header-only privacy scan, per-file cache, chip/row wording, the statement and limits), `RunStatus` (`ItemStage`, `ItemStageTracker`, progress/ETA wording), `Conditions` (`Condition` = `ConditionCheck` + `negated`, saved as the check or `{"not": check}`; `ConditionalStep`), `ConditionCheck` (every check and how it matches), `ConditionValues`/`ConditionMetadata` (text, date, aspect, bit depth, color space and metadata-field tests), `ConditionalActions` (branch actions, `PresetLink`, `PresetLibrary`: one per presets folder, passed by the app, CLI and jobs to the batch, preview and estimate), `BoundedRegex` (condition and rename patterns stop after 50 ms), `ConditionResolution` (`Pipeline.resolved(for:)` → `ResolvedPipeline` with a disposition: process, copy original, skip; plus subfolder, tags and note templates), `ConditionSummary` (words only), `SubfolderTemplate` (per-folder rendering and sanitising; `FinderTags`), `ItemFacts` (+`Metadata`: header-only facts a condition tests; `FactNeeds` for XMP, frame count and the alpha scan), `ConditionPreview` (`ItemFactsCache` actor: the preview's counter number and branch chips, facts cached per file version), `BatchRunner+Conditions` (per-item resolve, names and plans; copy original),
    `Jobs` (`Job`, `JobSettings`, `JobStore` over `TemplateStore` in `jobs/`, `JobSchedule`), `ProcessedLedger` (`jobs/<id>.ledger.json`: processed inputs with failed-attempt counts, give up after 3, and the job's outputs, each capped separately),
    `FolderWatcher` (FSEvents watcher, `ReadinessTracker` 2 s stability state machine, `WatchFilter`), `JobScheduler` (schedule timers), `JobRunQueue` (one run per job, coalesced follow-up), `JobCoordinator` (the app's job state machine: per-job
    queue, one job batch at a time, pause/off pruning, deferred re-arm; plus `JobNoticeCoalescer`), `JobLock` (`flock` per job
    across processes),
    `FolderAccess`/`JobFolders` (security-scoped bookmarks, stale refresh, moved folders, plain-URL fallback),
    `JobRunner` (candidates → ledger and 2 s stability check → `BatchRunner` → ledger update → report file), `ProcessingReport` (run summary + entries),
    `ReportExporter` (CSV with formula-injection guard, JSON with sorted keys, text, escaped self-contained HTML in `ReportExporter+HTML`), `ErrorLog` (rotating failure log), `RunHistory` (stored runs, 100 kept), `ZoomMath` (`ZoomState`, zoom around an anchor, pan, clamping), `WindowLayout` (main window size rules and frame maths), `NameReplacement` (find/replace in names, plain or regex), `SizeEstimator` (encodes a full-size render for the size estimate), `QualityLadder` (one image at several qualities), `ImageDifference` + `RegionCrop` (difference view maths, small region copies), `BrowserNavigation` (grid keyboard movement), `FileIdentity` (same-file keys by volume and inode), `ImageLoader+DataSize` (header-only size of encoded data), `MetadataEditorState` (Location "Set" fields), `NameTransforms` + `RenameRendering` (rename character/case rules; one renderer for batch and preview), `SizeInput` (KB/MB size field), `StoredFile` (hardened file reading for presets, templates, jobs, the journal); `SVGSanitizer+Parser`/`+Prolog`/`+Style`/`+References` and `MetadataOps+XMP`/`+Keep` are described with their main files
- `Sources/ImageconverterCLIKit/`: the command line (hand-written `CLIParser`, `CLICommand` (parsed commands, usage errors), `CLIOutput` (signal-driven stop, output), `CLIRunner`, `ConvertCommand`, `ListCommands`, `CLIDataDirectory`: the app's container when it exists, else Application Support, `--data-dir`); `Sources/ImageconverterCLI/main.swift` is a thin wrapper (product `imageconverter-cli`, installed as `imageconverter`; tests in `Tests/ImageconverterCLITests/`). Core: `AppInfo.version` (kept equal to `VERSION` by a test), `PipelineFile`
- `Resources/`: `imageconverter.sdef` (AppleScript dictionary) and `Info-fragments.plist` (NSServices, document types,
  AppleScript and URL-scheme keys); not used by SwiftPM, merged into the bundle by milestone 6's release script.
  Their logic is in Core: `URLAction` (link parsing), `ExternalRequests` (script/service checks), `ServicePins`
- `Tests/ImageconverterCoreTests/`: tests (operations on small generated images, rename tokens,
  resize/crop maths, collisions, preset round-trip and rejection, metadata really stripped, decode limits on
  hand-built header-only files in `Support/HeaderFixtures`, privacy scan before/after a real batch). `NoNetworkTests`
  scans `Sources/` and fails on networking APIs or web URLs outside comments (XML/XMP namespace names allowlisted)
- `scripts/`: `release.sh`, `install-cli.sh`, `Info.plist.template`, icon scripts, and the screenshot tooling: `screenshots.sh`
  (drives it), `make-sample-images.swift` (synthetic samples), `window-id.swift` (CGWindowList helper), `shrink-png.swift` (scale + colour reduction with ImageIO, ≤ 400 KB target)
- `docs/screenshots/`: the README images, `samples/` (generated sample images), `pipelines/` and `jobs/` (JSON the script loads)
- `docs/superpowers/specs/`: design documents; `docs/superpowers/plans/`: implementation plans
- `scripts/release.sh [--notarize]`: universal release build → `dist/imageconverter.app` (Info.plist from
  `scripts/Info.plist.template` + `Resources/Info-fragments.plist`, version from `VERSION`, build = commit count;
  `AppIcon.icns` via `scripts/make-iconset.sh`; CLI at `Contents/Helpers/imageconverter`), signs (`SIGN_IDENTITY`,
  default ad hoc `-`; hardened runtime; app with `Resources/imageconverter.entitlements`, CLI unsandboxed),
  verifies, zips + SHA-256. `--notarize` needs a real identity and `NOTARY_PROFILE` (keychain profile);
  never run it or sign with a real identity unless Johan asks. `BUNDLE_ID` there must equal
  `CLIDataDirectory.bundleIdentifier` (the script checks). `scripts/install-cli.sh` links the CLI into `~/.local/bin`.
  `dist/` is gitignored. Credentials stay in the keychain.

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
