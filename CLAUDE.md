# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS app for batch image processing: the user drops images/folders, builds a pipeline
(resize, crop, rotate/flip, redact, canvas, color (profile, re-color, reduce colours), adjust, watermark, then metadata, rename, output format)
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
    `AppSettings.swift` (output mode, persisted in UserDefaults; also `afterRun`, key `afterRunAction`, and
    `notificationsDenied` for the "When finished" note), `AppModel+AfterRun.swift` (`runAfterRunAction`: reveal in
    Finder and/or notify via Core `AfterRunAction.plan`/`notification(for:summary:)`), `PipelineSection.swift` (step rows,
    reorder, add, fixed Output row), `StepEditors.swift` (one editor per step kind), `AdjustEditor.swift` (Adjust step sliders; Soft ↔ Sharp is centred, `fillOrigin: 0`) with `AdjustPresetsMenu.swift` + `AdjustPresetsModel.swift` (Presets menu: built-in looks and saved presets, save/duplicate/rename/delete, injected with `.environment`), `WatermarkEditor.swift` (watermark step editor) with `WatermarkControls.swift` (sliders, rotation, layout, shadow, outline), `WatermarkTemplatesMenu.swift` + `WatermarkTemplatesModel.swift` (templates menu and store, injected with `.environment`), `WatermarkThumbnail.swift` (chosen image, SVG refusal reason), `AppModel+WatermarkText.swift` (live token text), `NameSheet.swift` (name sheet for presets and templates), `StepControls.swift` (shared controls),
    `FileStepEditors.swift` (Metadata and Rename rows), `MetadataEditor.swift` + `MetadataDateEditor.swift` + `MetadataCustomFieldsEditor.swift` (Metadata editor groups), `MetadataTemplatesMenu.swift`/`MetadataTemplatesModel.swift` (templates, like the watermark ones), `RenameEditor.swift` (Rename editor; the live rename example is computed in `AppModel`),
    `ConditionEditor.swift` (if/then/else editor: match, condition rows with a Not switch), `ConditionKind.swift` (the grouped kind picker),
    `ConditionControls.swift`/`ConditionValueControls.swift` (value controls per kind: numbers, text, dates, metadata fields),
    `ConditionActions.swift` (Then/Else action lists reusing the step editors; grouped + Add menu) and `ConditionActionEditors.swift` (subfolder, tags, preset, keywords, note; `{labels}` in the token menu),
    `ConditionContentControls.swift` (content checks: Shows with the searchable label picker over `SystemImageAnalyzer.knownLabels`, face count, text, aesthetics, screenshot; "Needs macOS 15" reason from `ConditionKind.unavailableReason`),
    `PresetBar.swift` and `AppModel+Presets.swift` (preset picker, save/rename/delete),
    `PreviewPane.swift` (before/after, Original | Result table, run progress bar), `ComparisonViews.swift` (side by side, split, difference, single), `QualityPanel.swift` (quality ladder tiles), `CompareController.swift` (compare and browser modes, per-selection difference and ladder) and `CompareController+Keys.swift` (Space/B monitor, only while Single mode is shown), `AppModel+Compare.swift` (difference/ladder renders, list facts), `Checkerboard.swift`, `BatchBrowser.swift` (filmstrip, grid, resizable area) and `BatchTable.swift` (list),
    `ZoomableComparison.swift` (`ZoomController` on the model: synced zoom shared by both preview sides and the View menu; pinch/scroll/drag NSView overlay; `overlay` draws the clipping mask at the same zoom),
    `HistogramPanel.swift` (`HistogramState` on the model: `showHistogram`/`showClipping`/`histogramSource` keys from `ViewDefaults`, the result's `ClippingMask`; `HistogramToggle` in the preview header, `HistogramPanel` + chart in the preview's bottom-left corner; View ▸ Show Histogram ⌥⌘G / Show Clipping ⌥⌘J; the mask is made off the main actor by `AppModel.renderClippingMask`, a `.task(id: clippingKey)` in `PreviewPane`),
    `AppModel+Preview.swift` (selection, 300 ms debounced render task with a generation counter, histograms measured in that task off the main actor (`measured`), thumbnail cache).
    `WindowSizer.swift` + `WindowSizer+Height.swift` (apply `WindowLayout`: fixed 360 pt sidebar; height from the sidebar's
    measured parts: pipeline collapsed → exactly the content; expanded → user-resizable, the chosen height remembered in
    `expandedWindowHeight`, extra height as a gap above Output, steps scroll when shorter; preview open → width resizable,
    min 780; the preview width toggle animates via `NSAnimationContext`; the root view applies its ranges with
    `.windowResizability(.contentSize)`; full screen is off), `SidebarMotion.swift` (every height change: the sidebar
    animates one value, `SidebarHeightReporter` reports it per frame and the window is set to it in the same pass, so
    the edge and content move together; wrap height-changing edits in `SidebarMotion.perform` / `.sidebarAnimated`),
    `EdgeHandle.swift` (grab handles on the panel edges), `OutputPanelHandle.swift` (`CollapsibleOutputPanel`: the Output
    panel's top-edge handle; click collapses to the `OutputSummary` line, drag sets `outputHeight` while
    `WindowSizer.pinHeight`/`releaseHeight` keep the window height; `OutputPanelState` (`model.outputPanel`) persists
    `outputCollapsed`/`outputHeight`). DEBUG: `-debugTogglePipelineEvery <s>`, `-debugStepCycle <s>`,
    `-debugWindowHeight <pt>`.
    `RunMonitor.swift` (live stages via an ordered event stream, `RunMetrics`, 1 s `ResourceSampler` while running),
    `RunStatusViews.swift` (progress area, Performance panel, thumbnail `StageRing`, interrupted-run sheet),
    `AppModel+Performance.swift` (pause, Process Next, low-memory mode, run journal path and resume).
    `ReportView.swift` (summary cards, export menu, per-file table, error log sheet), `HistoryView.swift` (History window, `HistoryController`), `AppModel+History.swift` (manual runs recorded once; jobs record in `JobsController.record`).
    `PrivacyPanel.swift` (shield chip, panel with each finding's values and links to the metadata panel, the opt-in faces/text check and "Add a Redact step", Help ▸ Privacy… window) and `AppModel+Privacy.swift` (scan task, `PrivacyState`, the content check task and `privacyLooksForContent`); `QuitCoordinator.swift` (⌘Q while running).
    Metadata panel (right of the preview, shown only with it, closed by default): `MetadataInspector.swift` (panel, search,
    Add Field sheet, `InspectorEdge` width drag, `InspectorToggle` in the preview header), `MetadataInspectorRow.swift` (rows,
    value editor), `AppModel+MetadataOverrides.swift` (`overwritesOriginals` environment value: amber note in Overwrite originals mode; `InspectorState`: `inspectorOpen`, privacy-link focus, edited sources
    for the badge; per-image overrides live in `items[i].metadataOverrides`, so removing/clearing drops them; no edits
    while running). `WindowSizer` adds the panel width (`inspectorWidth`, 260–560) when it opens; DEBUG
    `-debugShowInspector`, `-debugEditMetadata <title>`.
    `AccessStore.swift` (sandbox folder grants: `folderGrants` bookmarks, session roots, `ensureAccess` before every
    `startRun` with pre-filled open panels; only when `Sandbox.isActive`, DEBUG `-debugSimulateSandbox`) and
    `FolderAccessWindow.swift` (Help ▸ Folder Access…, with Add Folder…; Remove is refused while a batch or job runs).
    `AppSettings` keeps `outputFolderBookmark` (rebuilt whenever a folder is chosen, also the same one).
    `AppModel+Access.swift` (refreshes stale watermark bookmarks in the edited pipeline), `AppModel+ClearAll.swift`
    (More ▸ Clear All…), `AboutView.swift` (About window), `AdjustSliderControl.swift` (Adjust slider with double-click
    reset), `StepHelpHover.swift` (1.5 s hover help boxes from Core `StepHelp`), `WindowDropTarget.swift` (file drops
    anywhere in the window; `addDroppedFiles` environment action so step rows' String drop targets pass file
    locations on instead of swallowing them). `AppDefaults.swift` (the settings store; DEBUG `-debugDefaultsSuite`),
    `ResizeEditor.swift` (Resize editor), `MLEnlargeControls.swift` (ML enlarge factor, model state, Download… with the one-time consent alert) and `MLEnlargeDownload.swift` (`MLEnlargeModel`: status, progress polling, `mlEnlargeDownloadConsent`; the only caller of `downloadConfigurationModel`, a test checks; DEBUG `-debugMLEnlargeStatus <status>` is read by Core `SystemSuperResolution.simulatedStatus`, so preview and batch see it too, and never downloads), `RedactEditor.swift` (Redact editor, with `RedactSizeRow` for Blocks across / Strength: `AdjustSliderControl` over `RedactOptions.acrossRange`, double-click Auto, "Saved as N px" for old steps),
    Updates: `Update/` (`UpdateClient.swift` is the only file allowed to use the network): `UpdateClient.swift` (API URL + User-Agent, ephemeral
    `URLSession`, host check on the first URL, every redirect and the response, byte caps while streaming),
    `UpdateVerifier.swift` (download folder `imageconverter-update-<uuid>` in the container tmp, the name the service
    expects; SHA-256 check for quick feedback),
    `UpdateInstaller.swift` (`prepare` before downloading: refusals incl. no bundle/no installer service, translocated/read-only location;
    `install`: running re-check, then one XPC call to the installer service; `cleanUp` after an interrupted update;
    relaunch as a new instance then terminate), `UpdateController.swift` (`@Observable` state, the
    `updateCheckOnLaunch` answer, launch check once from the main window's onAppear, Check Now, install, Later);
    `UpdateViews.swift` (About section, offer sheet with plain-text notes, first-launch question, `updateSheets` held
    back while the interrupted-batch sheet shows). `GeometryEditors.swift` (Rotate/flip, Perspective, Trim editors; Crop and Canvas are in `StepEditors.swift`), `ColorEditor.swift` (the Color step: Profile, Re-color, Reduce colours), `FocusPicker.swift` (Focus: Position/Subject/Faces, used by Crop and Resize fill),
    `OutputRow.swift` (`OutputFormatControls`: format, quality and compression controls, an `accessory` right of the
    format picker), `OutputVariantsSection.swift` (round 3: every extra output is a full output panel under the main
    one's Save to: collapsible `VariantPanel` with name, format controls, size, suffix and `VariantSaveToControl`
    (beside main / same folder / subfolder next to original / new folder, never overwrite; a chosen folder is
    `AccessStore.remember`ed); `AddOutputButton`, the "+" at the top right of the Output panel; open panels in
    `model.outputPanel.expandedVariants`), `EstimateInfoButton.swift` (the ⓘ right of the main format picker: a
    non-activating child window (`HoverBox`, never key) on hover, click/Space pins it, every output's size via `SizeEstimator.lines`; DEBUG `-debugShowEstimateInfo`) and
    `AppModel+Variants.swift` (add (`OutputVariant.added`)/remove, `variantProblems`; Run is disabled while there are any;
    `confirmVariantFolders` before every run; `VariantFolderTrust`: cached "Choose the folder again" state for the panels).
    The open Output panel's natural height is capped at `OutputPanelSizing.maxOpenHeight` (60 % of the screen); taller
    content scrolls.
    `previewCollapsed` and `pipelineCollapsed` are persisted in UserDefaults
  - Jobs: `JobsController.swift` (+ `JobsController+Runs.swift`: watchers, schedules, the per-job run queue,
    background runs at half the cores, history/error log, bookmarks via `JobFolders`), `JobsView.swift` (Jobs
    window, ⌘J), `JobEditor.swift` (edit sheet), `SaveToControl.swift` (shared Save to), `JobNotifier.swift`
    (UserNotifications, only with an app bundle; one `JobNotifier.shared`; `NotificationRouter`, the notification
    delegate set at launch: a run notification brings the main window forward through `ExternalActions.showWindow`
    with the Report open, a job's just the app), `MenuBarContent.swift` (menu bar mode), `AppModel+Jobs.swift`,
    `QuitCoordinator.swift` (`applicationShouldTerminate`: asks, stops batch and job runs, waits, cleans up).
    `ExternalActions.swift` (`AppDelegate`: services provider, the `kAEGetURL` link handler and the `kAEOpenDocuments`
    handler for files opened with the app (not `application(_:open:)`, which lets SwiftUI open a window per file);
    the bridge to the model, which waits at launch for the main window; confirmation sheets, background converts), `ServicesProvider.swift` (Finder services), `Scripting.swift`
    (`NSScriptCommand` subclasses named in the sdef), `URLActions.swift` (confirmed link actions);
    `AppModel+RenameExample.swift` (the Rename editor's live example, using the selected image's resolved branch)
  - Shortcuts (App Intents, `Intents/`): `ConvertIntents.swift` (Convert Images, Apply Preset to Folder, Strip
    Metadata, Resize Images, Convert Format), `InfoIntents.swift` (Run Job, Get Image Metadata), `IntentEntities.swift`
    (`PresetEntity`/`JobEntity` by name with suggestion queries, `ImageFormatOption`), `AppShortcuts.swift` (phrases),
    `IntentSupport.swift` (`IntentFailure` plain-message errors, `IntentContext.convert`, `IntentInputs`: Shortcuts'
    file URLs with their security scope, else a copy of the data). All `openAppWhenRun = false`; thin over Core
    `Automation` (run with `BatchResourceLimits.background`, like jobs). `AutomationRuns.swift` (the actions converting now:
    `QuitCoordinator` cancels and waits for them; each converting action is recorded in History as "Shortcuts: preset";
    `IntentInputs.copies` removed when the action ends). `ImageconverterShortcuts.parametersChanged()` (calls
    `updateAppShortcutParameters` at launch and after presets/jobs change). `JobsController+Waiting.swift`: `runNowAndWait` (Run Job waits for the run's `JobRunResult`).;
    `AppModel+AltText.swift` and `PreviewAltTextRow.swift` (the preview's Alt text row: `PreviewAltText`, generated from `PreviewResult.altTextRequest`
    through `PreviewRenderer.altText(for:)`, cached per file version + enabled steps); `MetadataEditor` holds
    `AltTextControls` (hidden below macOS 27 unless used; disabled with the system's reason when not available)
- `Sources/ImageconverterCore/`: all logic: the pipeline model, each operation as a pure function
  (`CGImage → CGImage`, metadata → metadata), rename templating, collision naming, presets
  (JSON, `schemaVersion`), the batch runner. No SwiftUI here. Files so far:
  - `OutputFormat` (formats, `OutputSettings`), `ConversionError`, `ImageLoader`, `ImageEncoder`,
    `InputCollector` (files/folders to items), `OutputPlanner` (destinations per output mode),
    `FileCommitter` (atomic writes, trash replaced originals, temp file pattern, `cleanUp(in:)` for cancel/quit/stale temps),
    `DecodeLimits` (the one gate before any pixel decode: pixels, side, memory, file size, decompression-bomb heuristic; `ImageLoader.load`/`thumbnail` use it),
    `PrivacyScanner` (header/metadata-only privacy findings with severities, values (`PrivacyDetail`: escaped, ≤ 200 chars, with the field's `MetadataPath`) and suggested `MetadataOptions`),
    `MetadataOverrides` (`+Codable` strict; the run journal stores each item's overrides, `RunJournal.Item.metadataOverrides`, so resume keeps them) (the metadata panel's per-image overrides: set/remove standard, rating and allowlisted fields, remove any
    path; `Pipeline.metadataOverrides` (not saved) → `effectiveMetadata` before `MetadataOps.output`, `finish` (removals, rating)
    after it, so preview/estimate/batch/lossless/extra outputs share it; set wins over the step, removal wins, the step's floor
    stays for the rest; a copied original with overrides is converted), `MetadataInspection` (+`Text`: escaping; +`Groups`: GPS,
    grouping, XMP twins; header-only read for the panel), `BatchRunner` (parallel run, progress, cancel), `BatchResourceLimits` (`.background`: half the cores and budget for jobs and Shortcuts), `BatchRunner+Schedule` (the scheduler: adaptive limits, pause, priorities, end-of-batch retry, events, journal), `BatchControl` (pause/resume/prioritize/low-memory, `ItemEvent`, memory pressure, `BatchLimits`), `RunJournal` (interrupted-run journal with a `.done` completion log appended per finished item and, in overwrite mode, per-source fingerprints so a resume skips replaced originals; bookmarks of source folders, loose source files (≤ 2 000) and the output folder, made and resolved in `RunJournal+Access`; stale temp folders), `ActiveSources` (in-process registry of files runs are working on; a held file is skipped as "Busy in another run"), `PlannedDestinations` (in-process registry of output names runs have planned, keyed by `FileIdentity.pathKey`; `DestinationClaims`: one run's claims, released per item and at the run's end; `FileCommitter`'s exclusive `renamex_np(RENAME_EXCL)` picks the next free `_n` of `PlannedOutput.naming` (`OutputNaming`, names fitted to 255 by `OutputPlanner.nameLength`: NFD UTF-16 units, as APFS counts) when the planned name is taken and returns the URL written), `Pipeline+DecodeHint` (when the batch may decode downsampled), `SharedCIContext` (the one Metal-backed `CIContext`), `ImageHistogram` (preview histogram on a ≤ 1024 px 8-bit sRGB copy: RGB + Rec. 709 luminance bins, pixels with alpha < 8 skipped (premultiplied rounding), highlight/shadow fractions, `warnFraction` 0.1 %, `clippingMask` ≤ 2048 px red/blue, `displayPeak` 99.5th percentile; `PreviewResult.withHistograms`),
    `Pipeline` (steps, options, `apply`), `FileSteps` (`MetadataOptions`, `RenameOptions`), `MetadataOps` (metadata stripping/setting, DPI; `+XMP` builds the XMP written via `CGImageDestinationAddImageAndMetadata`, `+Keep` the remove-all keep lists; `Pipeline.outputProperties` in `Pipeline+Resize` applies both; it also has `outputDPI` and the Lanczos memory count for `peakPixels`), `MetadataEdits` (location, date, keyword and keep choices), `MetadataFields` (allowlisted custom EXIF/IPTC/XMP fields), `MetadataDates` (date set/shift), `MetadataFloor` (the Metadata step's removals as a floor for condition overrides; copies that must lose metadata are converted), `LosslessMetadata` (metadata-only edits: JPEG/HEIC image data copied untouched with `CGImageDestinationCopyImageSource`, a JPEG copy rebuilt by `JPEGSegments` (segment allowlist, JFIF thumbnail dropped, APP13 reduced to the re-encode's IPTC, EXIF thumbnail cut off), a HEIC copy refused with a thumbnail, extra images or auxiliary data, then checked against a tiny re-encode of the same metadata (XMP by value), falling back to the re-encode with a note; used by `BatchRunner.encodeItem`, so the estimate matches),
    `RenameTemplate` (tokens, sanitising; `+Values`: each token's value, `{random}`/`{uuid}` derived from the source path;
    `RenameTokens`: the grouped Insert menu, every known token in it), `OutputDestination` (extra outputs' Save to: `.folder(VariantFolder)` path + bookmark, `.sameFolder`,
    `.subfolder(template)`; `VariantFolder.resolution`: a bookmark is followed only when security-scoped (or, unsandboxed,
    naming the stored path), else `.unconfirmed`; `Pipeline.checkingVariantFolders` (the app's pre-run step: moved/stale
    rewritten, unconfirmed asked for in `AppModel.confirmVariantFolders`, once per folder); `VariantFolderPolicy` (`.confirmedOnly`
    default for jobs and Shortcuts, the app's run passes `.confirmedOr(chosen:)` with the folders chosen in its panels
    (written even without a bookmark), CLI passes `.trustPaths` and prints `folderDescription`, also for `jobs run`); `OutputVariant.baseFolder`, `.added`;
    `VariantFolderAccess`: chosen folders resolved and opened once per run, held by `RunPlan`), `OutputPanelSizing` (+ `OutputSummary`,
    `ViewDefaults`: Split is the default compare mode; `applySplitDefaultOnce` sets it once per install, flag
    `compareModeDefaultSplitApplied`, over the `ViewDefaultsStore` protocol), `Pipeline+PresetName` (`presetName` for `{preset}`, never saved
    or compared), `StepSummary` (one-line step descriptions), `Geometry` (size maths; `focusedOrigin` centres a crop on a focus),
    `CropFocus` (Crop/Resize fill focus: anchor, subject, faces; `FocusResolution`: fallbacks faces → subject → centre with report notes, union, pure), `VisionDetector` (protocol: normalised top-left face/subject/text rects; `SystemVisionDetector` on a ≤ 1024 px `VisionInput` copy; an image with alpha is flattened (`prepared(_:maxSide:background:)`): faces on mid grey; text on white and on black (copy and tiles, boxes joined) only when the ≤ 2048 px copy has a pixel with alpha < 255 (`textBackgrounds(forCopy:)`, early exit), else one pass as before; shared seam for later Vision features), `FocusDetector` (`FocusContext` passed to `Pipeline.apply`, `FocusCache` for the preview, estimate and ladder keyed by file version + step input; a failed detection isn't cached; `redactActivity` tells the preview while it waits: "Finding faces and text…", `RedactTarget.findingStatus`, `AppModel.previewDetecting`), `SharedDetections` (behind `FocusCache` and `RedactCache`: concurrent lookups share one detection in progress, run in its own task (`DetectionExecutor` on macOS 15, off the cooperative pool), at `.userInitiated`; when every waiter left it keeps running for a 2 s grace (`defaultGrace`) for a new waiter, then is cancelled; `cancelIdle`/`cancelIdleDetections` (the preview's `purge`, `removeAll`) cancels unwaited ones at once; rejected results (failures, cancellations) reach every waiter and aren't kept), `Pipeline+Focus` (a Crop or Resize fill step's detected focus at its position), `EnlargeCache` (ML enlarge results for the preview, estimate and ladder, one enlarge at a time app-wide, ≤ 2 results / 200 MP; `PreviewCaches` bundles it with `FocusCache` and `RedactCache`, `PreviewRenderer.caches` passed to `SizeEstimator`/`QualityLadder`),
    `ResizeModel` (`ResizeMode`, `ResizeOptions` with resampling and DPI; `.mlEnlarge(factor:)` plans as a plain scale), `MLEnlarge` (`MLEnlargeAvailability` with the refusal texts, `SuperResolutionScaler`/`Session` protocols (tests inject a fake; `FocusContext.enlarger`, `BatchHooks.enlarger`), `MLEnlargeTiling` (≤ 1920 px tiles, ≥ 64 px overlap, inside the image), `checkLimits`, `workingPixels` (+ `modelSessionPixels`) for `peakPixels`; refusals worded for the app (`SystemSuperResolution.inApp`, passed by `AppModel.startRun` unless `external`, the preview, estimate and ladder) or for jobs/CLI/services (`.shared`); `waitForModel` (60 s per tile); `BatchFailure.awaitsModelDownload` keeps jobs from counting it as an attempt; working space: the standard-range version of extended/linear spaces, else sRGB; `+Run`: tiles → 4× → Lanczos to 2×/3× → feathered strips, alpha by Lanczos; `+System`: `SystemSuperResolution` over VideoToolbox's `VTSuperResolutionScalerConfiguration` (RGBA half-float buffers), compiled only with `#if compiler(>=6.2) && !NO_MACOS26_SDK` so CI's Xcode 16 builds the `.unsupportedOS` fallback; never downloads), `Resampler` (Lanczos via vImage, bicubic via Core Image, bilinear/nearest via Core Graphics), `SizePresets` (aspect ratios, social and resolution sizes), `ImageOps` (resize, crop, canvas, color profile; `color` runs the Color step: profile → `Recolor` → `ColorReduce`), `ColorOptions` (the Color step's settings, JSON kind still `colorProfile`: the plain profile string while the rest is default, else an object; `HexColor` sRGB hex, `RecolorOptions`, `ColorReduction`, `Pipeline.reducesColors`), `Recolor` (tint, duotone, sepia, replace colour, hue shift in OKLab on a linear extended-sRGB float copy, parallel rows), `ColorReduce` (+`Pixels`: ≤ 512 px sample, full-image histogram when the sample is too sparse, median cut + k-means, 6-bit nearest table with exact search in cells holding a palette colour, serpentine Floyd–Steinberg, deterministic; one 8-bit buffer handed to the result, registered in `ReducedImages`), `IndexedPNG` (palette PNG only from the Color step's own result via `ReducedImages`, ≤ 256 sRGB colours with 0/255 alpha, `tRNS` spliced after ImageIO's `PLTE`; `CompressionSearch.encode(indexedPNG:)`), `ImageOps+Watermark` (watermark drawing: rotation, tiling, shadow, outline), `Redact` (`RedactOptions` with text → solid colour defaults and `retargeted`, `Redaction`: box geometry with padding, filter strength (Auto = 3, or `RedactOptions.blocksAcross`/`blurAcross` 2…5: the area's shorter side / N, never below the floor; old fixed px `fixedBlockSize`/`fixedBlurRadius` (`blockSize`/`blurRadius`) still drawn as before until `withAcross` clears them; `PreviewResult.redactSizeNote` shows their raised note), notes, faces on one ≤ 2048 px copy, text on the full step image (`SystemVisionDetector.textRects`: accurate recognition + text rectangles on the ≤ 2048 px copy, plus recognised lines in `TextTiles` 896 px tiles with 192 px overlap for larger images, at most 2 images' tiles at a time process-wide (`TextTiles.gated`); boxes cover each line's quad; fixed sizes raised to `Redaction.minimumFixedSize` with a report note), `TextBoxes`: every recognised line and text rectangle is redacted, overlaps merged only for the count; `SystemVisionDetector` throws `VisionInputError` when it can't make its working copy; a failed detection throws `ConversionError.redactUnchecked`: Redact fails closed; copies a condition makes are converted to redact in `ConditionResolution`), `MetadataOps+FaceRegions` (face/person regions dropped from the output XMP when faces are redacted), `ImageOps+Redact` (blur/pixelate/fill only inside the rects, everything else copied), `RedactDetector` (`RedactCache` for the preview, `Pipeline.redactInsertionIndex`/`add`/`addRedaction`), `ContentPrivacy` (the privacy panel's opt-in faces/text check, `ContentCheck` with the Redact detection, failures shown), `Rotation` (rotate/flip options, arbitrary angle and straighten, rotation geometry), `Perspective` (keystone + Vision auto correction via Core Image; output size fit/keep original, empty areas crop/colour/transparent/extend edges, one render; `+Geometry`: `Quad`, largest inner rectangle, output size; `+Homography`: the square-to-quad map and its inverse for extend edges; `cropRule` innerEnds for steps saved before 1.4, switched by `applyUserEdit`; Transparent is flattened per output by `Pipeline+Matte` `matted`, called by the batch's main and extra outputs, the quality ladder and the preview), `Trim` (border trimming), `Watermark` (options, layout, shadow/outline, placement maths), `WatermarkText` (per-item token context and rendering), `WatermarkTemplates` (watermark templates and built-ins on `TemplateStore`), `SVGSanitizer` (untrusted SVG: strict UTF-8, XMLParser, element/attribute allowlist, re-serialised; `+Prolog`: XML declaration and the one standard doctype; `+Parser`: the validating tree builder; `+Style`: simple `<style>` rules inlined as attributes; `+References`: style values, reference cycles and `use` expansion cap), `SVGRasterizer` (size-capped read, renders only the sanitised SVG via NSImage; never fetches), `Adjustments` (`AdjustOptions`, Core Image render in linear extended sRGB, output in the input's colour space and bit depth; `sharpness` is Soft ↔ Sharp, −100…100, negative = Gaussian blur scaled by `softenRadius`), `AdjustPresets` (the 16 built-in looks, `AdjustPresetStore` in `adjust-presets/`, `duplicate`), `WatermarkAssets` (image and SVG watermarks loaded once per batch, with the failure reason), `WorkWindow` (memory-aware batch scheduling), `AccessNeeds` (+ `Sandbox.isActive`: folders a run needs that aren't granted), `AccessPrompt` (the ask-for-folders loop without UI, `askToRead` for resume, and `FolderGrantList`), `ResumePlan` (what resuming an interrupted batch runs; readability, not existence, decides; `PausableClock`), `DropPayload` (file locations in a text drop), `ItemFacts+Metadata` (metadata facts for conditions), `ResettableSlider` (double-click reset maths; optional `fillOrigin` drawn by `ResettableSliderCell` for centred sliders (every Adjust slider with 0 in the middle; the fill ends at the knob's centre, inset by half the knob)), `StepHelp` (hover-help texts per step), `ImageWatermark` (path + bookmark), `CompressionSearch` (quality, target size, maximum size and smart (SSIM) compression, capped encode searches), `ImageSimilarity` (luma SSIM at ≤ 1024 px), `Update/` (`AppVersion`, `UpdatePolicy`: hosts, caps, asset names, `codeRequirement`; `UpdateRelease`/`UpdateError`, `UpdateInstallPlan`, `UpdatePackage`: checksum, zip entry check via `zipinfo`, `ditto` unpack, layout, symlinks, version; `UpdateSignature`: `SecStaticCode` check; `UpdatePackage+Unpack` (`unpack`/`runWatched`: ditto under a watchdog counting allocated size incl. forks and lost
free space, SIGKILL fallback; `unpackedTreeProblem`: the unpacked tree must match the zipinfo listing), `UpdateQuarantine`,
`UpdateInstallerProtocol` (the XPC interface), `UpdateReplacer` (+ `removeLeftovers`): stage a hidden copy beside the app and re-check it, rename old aside, rename new in, trash old, with injected `UpdateFileOperations`; zip `Limits`: 20 000 entries, 1 GB, 8 MB listing), `Presets`/`PresetSession` (preset files, built-ins, unsaved-change tracking), `PreviewRenderer` (actor: before/after for one item, caches the decoded source), `PrivacyScanner`/`PrivacyCache`/`PrivacySummary`/`PrivacyStatement` (header-only privacy scan, per-file cache, chip/row wording, the statement and limits), `RunStatus` (`ItemStage`, `ItemStageTracker`, progress/ETA wording), `Conditions` (`Condition` = `ConditionCheck` + `negated`, saved as the check or `{"not": check}`; `ConditionalStep`), `ConditionCheck` (every check and how it matches), `ConditionContent` (the content checks' matching and wording, `LabelMatch`, `LabelToken` (`{labels}` in tags/keywords: one entry per label)), `ImageAnalysis` (`ImageAnalyzer` protocol, `SystemImageAnalyzer`: classification, faces, fast text, macOS 15 aesthetics in one Vision pass; `supportsAesthetics` is the macOS 14 seam), `ImageAnalysisCache` (shared per file version, ≤ 1024 px upright thumbnail decode within `DecodeLimits`, failures not kept; concurrent misses for one file share one analysis, ≤ 2 analyses at once app-wide; `FactNeeds.analysis` bits, injected via `BatchHooks.analysis`, `ItemFactsCache(analysis:)`, `resolved(forSource:analysis:)`), `ConditionValues`/`ConditionMetadata` (text, date, aspect, bit depth, color space and metadata-field tests), `ConditionalActions` (branch actions, `PresetLink`, `PresetLibrary`: one per presets folder, passed by the app, CLI and jobs to the batch, preview and estimate), `BoundedRegex` (condition and rename patterns stop after 50 ms), `ConditionResolution` (`Pipeline.resolved(for:)` → `ResolvedPipeline` with a disposition: process, copy original, skip; plus subfolder, tags and note templates), `ConditionSummary` (words only), `SubfolderTemplate` (per-folder rendering and sanitising; `FinderTags`), `ItemFacts` (+`Metadata`: header-only facts a condition tests; `FactNeeds` for XMP, frame count and the alpha scan), `ConditionPreview` (`ItemFactsCache` actor: the preview's counter number and branch chips, facts cached per file version), `BatchRunner+Conditions` (per-item resolve, names and plans; copy original), `BatchReport` (the batch's result types; `convertedCount` counts images, `written`/`entries` every file, `extraFailures` the extra outputs that weren't written, `primaryOutputBytes` for the saved phrase), `OutputVariant` (extra outputs: `VariantResize`, suffix sanitising and validation, max 8, repeated ids renewed, `runBlocker`; `LossyVariant`; `Pipeline.extraOutputs`, `PipelineLoadNotes` for outputs left out on load, shown by the app at launch and on preset select, by jobs as a run problem and by the CLI as warnings), `AfterRunAction` (When finished: what to reveal, whether and what to notify), `RunCountsText` (in `ConditionPreview.swift`: run counts, `runSummary` for the toast and notification), `OutputPlanner+Variants` (`planVariants`: always new files next to the primary output, `_2` on any taken name), `BatchRunner+Variants` (`ItemPreparation` shares one decode and pipeline run, per-variant encode and commit after the primary, `peakPixelsWithVariants`),
    `Jobs` (`Job`, `JobSettings`, `JobStore` over `TemplateStore` in `jobs/`, `JobSchedule`), `ProcessedLedger` (`jobs/<id>.ledger.json`: processed inputs with failed-attempt counts, give up after 3, and the job's outputs, each capped separately),
    `FolderWatcher` (FSEvents watcher, `ReadinessTracker` 2 s stability state machine, `WatchFilter`), `JobScheduler` (schedule timers), `JobRunQueue` (one run per job, coalesced follow-up), `JobCoordinator` (the app's job state machine: per-job
    queue, one job batch at a time, pause/off pruning, deferred re-arm; plus `JobNoticeCoalescer`), `JobLock` (`flock` per job
    across processes),
    `FolderAccess`/`JobFolders` (security-scoped bookmarks, stale refresh, moved folders, plain-URL fallback),
    `JobRunner` (candidates → ledger and 2 s stability check → `BatchRunner` → ledger update → report file), `ProcessingReport` (run summary + entries),
    `Automation` (the Shortcuts actions' logic: `AutomationRequest` convert/strip/resize/convertFormat, `run` through
  `BatchRunner` into a new-folder output (one run per source format when each image keeps its own), scratch folders
  under `scratchBase` (removed after a day), `checkedFolder` (Folder Access message), `metadataText`, `message(for:)`),
  `PipelineOverrides` (the CLI's and the actions' format/quality/max-size/long-edge/variants/strip overrides),
  `ReportExporter` (CSV with formula-injection guard, JSON with sorted keys, text, escaped self-contained HTML in `ReportExporter+HTML`; the structured `ReportEntry.warning` flag is a JSON key, a CSV column and "(warning)" in text), `ErrorLog` (rotating failure log), `RunHistory` (stored runs, 100 kept), `ZoomMath` (`ZoomState`, zoom around an anchor, pan, clamping), `WindowLayout` (main window size rules and frame maths), `NameReplacement` (find/replace in names, plain or regex), `SizeEstimator` (encodes a full-size render for the size estimate), `QualityLadder` (one image at several qualities), `ImageDifference` + `RegionCrop` (difference view maths, small region copies), `BrowserNavigation` (grid keyboard movement), `FileIdentity` (same-file keys by volume and inode), `ImageLoader+DataSize` (header-only size of encoded data), `MetadataEditorState` (Location "Set" fields), `NameTransforms` + `RenameRendering` (rename character/case rules; one renderer for batch and preview), `SizeInput` (KB/MB size field), `StoredFile` (hardened file reading for presets, templates, jobs, the journal),
    `AltText` (Metadata step's generated alt text: `AltTextAvailability` with plain-English reasons, `AltTextGenerator`
    protocol (tests use a fake; never run the real model in tests), fixed prompt, ≤ 1024 px sRGB model image, the
    sanitiser for model text), `AltText+Run` (30 s timeout on its own timer queue, counted from the item's turn, `generateBlocking` for the sync
    workers on `AltTextExecutor`; `AltText.asksModel` decides who takes a limiter slot; `AltTextSlot`: one generation per item shared by lossless copy,
    re-encode and extra outputs; `AltTextModelGate.shared` (`AltTextModelGate.swift`): one model call app-wide for every batch and the preview, held until its task really ends, FIFO turns with the preview first, circuit breaker after 3 timeouts in a row or a timed-out call still running at 60 s ("the on-device model stopped responding"); `AltTextWorkerLimiter.shared`: process-wide, ≤ half the cores (`AltText.batchWorkers`)
    of all batches' workers may be on items that generate, acquired asynchronously in the scheduler's worker task;
    `AltText.standardGenerator` is the default everywhere, swappable in tests),
    `AltText+System` (`SystemAltTextGenerator`: `SystemLanguageModel.default` only, never the server model (a test
    bans its name in Sources/); compiled only with `#if compiler(>=6.4) && !NO_MACOS27_SDK`, DEBUG
    `-debugAltTextStatus`). Written to XMP `Iptc4xmpCore:AltTextAccessibility` via `MetadataOptions.generatedAltText`
    (transient) in `MetadataOps+XMP`; the size estimate and quality ladder pass no generator (`ItemRunOptions.altText`); `SVGSanitizer+Parser`/`+Prolog`/`+Style`/`+References` and `MetadataOps+XMP`/`+Keep` are described with their main files
- `Sources/ImageconverterInstallerKit/` + `Sources/ImageconverterInstaller/main.swift` (product `imageconverter-installer`):
  the update installer XPC service, assembled by `release.sh` as `Contents/XPCServices/io.github.jozeta.imageconverter.installer.xpc`,
  signed without entitlements (not sandboxed: sandbox-created files are quarantined and can't be opened).
  `InstallerPolicy` (client requirement: Developer ID team + app identifier; `-Xswiftc -DUPDATE_E2E` builds accept
  `io.github.jozeta.imageconverter.updatetest` instead, for the end-to-end test only), `InstallRequest` (target app from the
  service's own path, the container download path rule compared as text, `O_NOFOLLOW_ANY` capped copy),
  `InstallerService` (perform: refuses a version not newer than the installed app's, every package check again on its own copy, leftovers, stage/re-verify/swap, quarantine removal; one install at a time;
  `InstallerListenerDelegate`). Tests in `Tests/ImageconverterInstallerTests/` on temp folders with a fake Trash
- `Sources/ImageconverterCLIKit/`: the command line (hand-written `CLIParser` (+`Variant`: `--variant key=value,…`), `CLICommand` (parsed commands, usage errors), `CLIOutput` (signal-driven stop, output), `CLIRunner`, `ConvertCommand`, `ListCommands`, `CLIDataDirectory`: the app's container when it exists, else Application Support, `--data-dir`); `Sources/ImageconverterCLI/main.swift` is a thin wrapper (product `imageconverter-cli`, installed as `imageconverter`; tests in `Tests/ImageconverterCLITests/`). Core: `AppInfo.version` (kept equal to `VERSION` by a test), `PipelineFile`
- `Resources/`: `imageconverter.sdef` (AppleScript dictionary) and `Info-fragments.plist` (NSServices, document types,
  AppleScript and URL-scheme keys); not used by SwiftPM, merged into the bundle by milestone 6's release script.
  Their logic is in Core: `URLAction` (link parsing), `ExternalRequests` (script/service checks), `ServicePins`
- `Tests/ImageconverterCoreTests/`: tests (operations on small generated images, rename tokens,
  resize/crop maths, collisions, preset round-trip and rejection, metadata really stripped, decode limits on
  hand-built header-only files in `Support/HeaderFixtures`, privacy scan before/after a real batch). `RedactCorpusTests` (real Vision on the generated `Support/RedactCorpus` text images: every legible text's ink inside a redacted rect; skipped when Vision finds nothing), `NoNetworkTests`
  scans `Sources/` and fails on networking APIs or web URLs outside comments (XML/XMP namespace names allowlisted;
  `URLSession`/`URLRequest` and `https://api.github.com/` only in `Imageconverter/Update/UpdateClient.swift`).
  `UpdatePackageTests` builds ad hoc–signed bundles in temp folders (refused by the real requirement);
  `UpdateReplacerTests` stages and swaps apps on temp folders with injected failures at every step
- `scripts/`: `release.sh`, `install-cli.sh`, `Info.plist.template`, icon scripts, and the screenshot tooling: `screenshots.sh`
  (drives it), `make-sample-images.swift` (synthetic samples), `window-id.swift` (CGWindowList helper), `shrink-png.swift` (scale + colour reduction with ImageIO, ≤ 400 KB target)
- `docs/screenshots/`: the README images, `samples/` (generated sample images), `pipelines/` and `jobs/` (JSON the script loads)
- `docs/superpowers/specs/`: design documents; `docs/superpowers/plans/`: implementation plans
- `scripts/release.sh [--notarize]`: universal release build → `dist/imageconverter.app` (Info.plist from
  `scripts/Info.plist.template` + `Resources/Info-fragments.plist`, version from `VERSION`, build = commit count;
  `AppIcon.icns` via `scripts/make-iconset.sh`; CLI at `Contents/Helpers/imageconverter`), signs (`SIGN_IDENTITY`,
  default ad hoc `-`; hardened runtime; app with `Resources/imageconverter.entitlements`, CLI unsandboxed),
  verifies, zips + SHA-256. `--notarize` needs a real identity and `NOTARY_PROFILE` (keychain profile);
  never run it or sign with a real identity unless Johan asks. It also builds the installer XPC service into
  `Contents/XPCServices` (signed without entitlements, checked: exists, verifies, `XPC!`, not sandboxed).
  `SWIFT_FLAGS` adds `swift build` arguments (`"-Xswiftc -DUPDATE_E2E"` only for the update end-to-end test build;
  refused with a real identity or `--notarize`, and a non-ad-hoc build whose service names `.updatetest` is refused).
  The signed app must have exactly its four entitlements. **Shortcuts:** after the universal build it runs Xcode's
  `appintentsmetadataprocessor` on `.build/out/Intermediates.noindex/…/Imageconverter-p.build/Objects-normal/<arch>/`
  (`Imageconverter.SwiftFileList` + `*.swiftconstvalues`, which the universal, Xcode-build-system `swift build`
  emits) and copies `Metadata.appintents` into `Contents/Resources/`; it checks every intent in its `intents=(…)`
  list is there with `openAppWhenRun` false, the action count equals the list and there is one App Shortcut each
  (add a new intent to that list). Needs Xcode (checked before building). `SKIP_APPINTENTS=1` skips the step and
  prints "App Intents metadata skipped (SKIP_APPINTENTS=1)"; CI sets it (its Xcode 16 differs from the processor
  arguments and build layout); refused with a real identity or `--notarize`. Chosen (Task 8, round 3) over `xcodebuild` on the package scheme
  (runs the metadata step only for library targets, not the executable) and a hand-written .xcodeproj. linkd
  indexes an app's actions only after it was launched from its location (never from /tmp). `BUNDLE_ID` there must equal
  `CLIDataDirectory.bundleIdentifier` (the script checks). `scripts/install-cli.sh` links the CLI into `~/.local/bin`.
  `dist/` is gitignored. Credentials stay in the keychain.

## Architecture rules

- Apple frameworks only, no third-party dependencies in v1: ImageIO (decode/encode/metadata),
  Core Graphics (pixel operations), ColorSync/`CGColorSpace` (profiles), Security + CryptoKit (update checks).
  Every imported framework must be listed in `PrivacyStatement.frameworkList` (a test checks).
- App Sandbox **on**: user-selected read/write only; network: `network.client` only, used solely by the opt-in
  update check/download in `Sources/Imageconverter/Update/UpdateClient.swift` (`NoNetworkTests` fails on networking anywhere
  else; `release.sh` requires client and forbids server). Folder access for
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
- Version 1.4.0 (in `VERSION`). Show it in the app (an About page, `--version` or a footer, read
  from that file). Bump it on every push that changes the app (patch: fixes, minor: features, major:
  breaking changes), and in the same commit move "Unreleased" under the new version and update the
  README's version and "What's new".
- The README stays detailed: what it is, installation, configuration and settings, how-tos, and
  screenshots in a grid with a caption under each.
- There is no GitHub remote yet. Don't push or create repos unless asked.
