# Histogram, Clipping and Bug-Check Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an RGB/luminance histogram with clipping warnings and a clipping overlay to the preview, then fix all 21 findings of the 2026-11-17 bug check, and make the main output an "Output 1" card like the extra outputs.

**Architecture:** Same split as always: pure, tested logic in `ImageconverterCore`, thin SwiftUI in `Imageconverter`, docs in the same task. Each bug fix starts with a failing test that reproduces it (superpowers:systematic-debugging + test-driven-development).

**Tech Stack:** Swift / SwiftUI, macOS 14+, Apple frameworks only (ImageIO, Core Graphics, Core Image, vImage/Accelerate, Vision).

**Spec:** Johan's request of 2026-11-17 ("do Histogram and clipping. then do all the bugs"), the bug-check findings (full entries with trigger, evidence and fix in the plan workspace, `bugs/bug-A.md` … `bug-G.md`, copied from the bug check), and his earlier list of the same day (Redact block size, Redact load time, general speed, "Output, Output 2, Output 3 all look the same nested under the headline"). Decisions not answered by Johan are the controller's, marked "(ruling)".

## Global Constraints

- Never edit `Sources/Imageconverter/DesignSystem/LadaGlass.swift`; Låda Glass components and tokens only; keyboard accessible; English.
- Never lose files; originals are only replaced in Overwrite mode; unrelated files never replaced (`_2`, `_3`, …).
- Preview, size estimate, batch, jobs, Shortcuts and CLI share one Core path; the preview's final image must equal what the batch writes.
- Saved presets/jobs/pipelines: old files load unchanged; new fields decode leniently; round-trip tests.
- CI is macos-15 / Xcode 16 / Swift 6.0: long `[UInt8]` `+` chains in tests use `concat(...)` (`Tests/ImageconverterCoreTests/Support/ByteConcat.swift`); type closures step by step; macOS 26/27 code stays behind the existing compiler guards.
- `swift test` and `swiftlint --strict` clean before each commit. Hover help (`StepHelp`), README (settings + how-to), CHANGELOG "Unreleased", CLAUDE.md layout updated per task.
- Agents follow `common.md` in the plan workspace (no app launches with real defaults, no `defaults write/delete` on the real app, no pkill/killall, no signing, no pushing, no model downloads).

## Review Focus

1. A pipeline with pixel-unit steps (crop px, watermark, sharpen, Redact) shows the exact batch result in the preview once it settles, never a proxy-scaled approximation (Task 6 test `testProxyNeverFinalForPixelUnitSteps`).
2. Transparent, 16-bit and wide-gamut (Display P3, extended range) images give a sensible histogram: transparent pixels are not counted; values above 1.0 count as highlight clipping (Task 1 tests).
3. Two batches started at the same time into one folder never replace each other's files, and in Overwrite mode never trash an original whose output was replaced (Task 4 test `testConcurrentRunsNeverReplace`).
4. A preset saved before this change with a fixed Redact block size loads and keeps a visibly matching result (Task 3 test `testOldFixedBlockSizeDecodes`).
5. Quitting while a Shortcut, a Run Job wait, or an update install is in progress never hangs and never leaves the app missing (Task 9 tests).

---

### Task 1: Histogram and clipping

**Files:** Create `Sources/ImageconverterCore/ImageHistogram.swift`, `Sources/Imageconverter/HistogramPanel.swift`; modify `PreviewPane.swift` (header toggle next to `InspectorToggle`, panel and overlay), `ComparisonViews.swift` (clipping overlay over every "after" image), `ImageconverterApp.swift` (View menu), `AppModel+Preview.swift` (histograms computed with the preview render, off the main actor), `OutputPanelSizing.swift`'s `ViewDefaults` (keys); tests `Tests/ImageconverterCoreTests/ImageHistogramTests.swift`.

**Interfaces — Produces:**
- `public struct ImageHistogram: Equatable, Sendable { public let red, green, blue, luminance: [Int] /* 256 bins each */; public let counted: Int; public let highlightFraction: Double; public let shadowFraction: Double }`
- `public static func compute(_ image: CGImage, maxSide: Int = 1024) -> ImageHistogram` — draws a ≤ `maxSide` copy into 8-bit sRGB RGBA (non-premultiplied values; extended/HDR values above 1.0 clamp to 255 and so count as clipped); pixels with alpha 0 are skipped; luminance = Rec. 709 (0.2126, 0.7152, 0.0722) of the sRGB values, rounded; highlight = any channel 255; shadow = all three channels 0.
- `public static let warnFraction = 0.001` (0.1 %): `isHighlightClipped`/`isShadowClipped` computed properties use it.
- `public static func clippingMask(for image: CGImage, maxSide: Int = 2048) -> CGImage?` — same thresholds; RGBA, highlight pixels opaque red (255,0,0), shadow pixels opaque blue (0,80,255), others transparent; size = the ≤ `maxSide` copy (the view scales it over the image).
- `PreviewResult` (or the app's preview state) gains `beforeHistogram`/`afterHistogram: ImageHistogram?`, computed from the preview's display images after each render.

**Behaviour (ruling, Johan asked only for "Histogram and clipping"):**
- Preview header: a "Histogram" toggle button (SF Symbol `chart.bar.xaxis`, accessibility label "Show histogram"), and View ▸ Show Histogram ⌥⌘H, View ▸ Show Clipping ⌥⌘J. Both off by default, persisted (`showHistogram`, `showClipping` in UserDefaults via `AppDefaults`).
- Panel: a Låda Glass surface in the preview's bottom-left corner, about 240×120 pt, a segmented Original | Result (default Result, persisted `histogramSource`), the R, G, B bins drawn as translucent filled areas (additive look) and luminance as a line, scaled to the 99.5th percentile bin so one spike doesn't flatten the rest. Under it two chips: "Highlights x.x %" and "Shadows x.x %", red text (`LadaGlass.Colors.badText`) when over `warnFraction`, clicking a chip turns on Show Clipping. Empty state: "No image selected"; while rendering: the previous histogram dimmed. Hover help explains it's measured on the preview image.
- Clipping overlay: when on, draws `clippingMask` of the Result over every Result image in all comparison modes (side by side, split, single, not difference), zoom-synced.

- [ ] **Step 1: Failing tests** in `ImageHistogramTests`: `testBinsAndCountsSolidColour` (a 10×10 sRGB (200,100,0) image → red[200] == 100, green[100] == 100, blue[0] == 100, luminance[Int((0.2126*200+0.7152*100).rounded())] == 100, counted 100); `testTransparentPixelsNotCounted` (half alpha 0 → counted 50); `testClippingFractions` (25 % white, 25 % black, rest grey → highlightFraction 0.25, shadowFraction 0.25, both clipped flags true); `testExtendedRangeCountsAsHighlight` (an extended-linear-sRGB float image with 1.5 → highlightFraction 1); `testSixteenBitInput` (16-bit image gives the same bins as its 8-bit twin ±1 bin); `testMaskColours` (white pixel → red opaque, black → blue opaque, grey → alpha 0); `testLargeImageIsDownsampled` (4000×3000 → counted ≤ 1024×768).
- [ ] **Step 2:** run `swift test --filter ImageHistogramTests` → fails (type missing).
- [ ] **Step 3:** implement Core; plain Swift loop over the 8-bit buffer (rows with `concurrentPerform` if > 1 MP).
- [ ] **Step 4:** tests pass.
- [ ] **Step 5:** UI as above; histograms computed in the preview task after the render, never on the main actor; cancelled with the render (generation counter).
- [ ] **Step 6:** README (Preview section: histogram, clipping, shortcuts), CHANGELOG Unreleased, CLAUDE.md layout, `swift test`, `swiftlint --strict`; commit `feat: histogram and clipping warnings in the preview`.

### Task 2: Redact finds text on transparent images (bug A1, HIGH)

**Files:** `Sources/ImageconverterCore/VisionDetector.swift:30-44, 155-186`, tests `RedactTransparencyTests.swift` (real Vision, `XCTSkip` when Vision returns nothing for the opaque control like `RedactCorpusTests`).

- [ ] Failing test `testDarkTextOnTransparencyIsFound`: black text on transparent at 1400 px and 3000 px → boxes cover the ink (same check as `RedactCorpusTests`); control black-on-white passes today.
- [ ] Fix: when the step image has alpha, run text detection on two flattened copies (onto white and onto black) and union the boxes (faces too: flatten onto mid grey once); count as one detection for the note. The content privacy check uses the same path.
- [ ] Tests pass; docs (README Redact: "transparent images are checked on light and dark backgrounds"), CHANGELOG; commit `fix(redact): find text on transparent backgrounds`.

### Task 3: Redact block size that always works (bug F1 / Johan's report)

**Files:** `Redact.swift:99-101, 242-244`, `RedactEditor.swift:96-106` (`RedactSizeRow`), `StepSummary`, `StepHelp`, tests `RedactBlockSizeTests.swift`.

**Ruling:** the size control becomes relative: **"Blocks across"**, the number of pixel blocks across each redacted area's shorter side, **2 (coarse) … 5 (fine, the existing privacy floor of shorter side / 5)**, Auto = 3, steps of 1, so every position gives a different result on any image size. Blur gets the same treatment: **Strength** as a fraction of the box's shorter side (radius = shorter side × 0.04 … 0.25, Auto 0.12), the existing floor kept.
- Saved JSON: new `blocksAcross: Int?` / `blurStrength: Double?`. An old fixed `blockSize`/`blurRadius` (px) keeps behaving exactly as today (px, raised to the floor, note); the editor then shows "Saved as N px; move the slider to switch" and the first edit switches to relative. Old files load unchanged.
- The preview's status line shows the raised note when a fixed old size was raised.

- [ ] Failing tests: `testEveryBlocksAcrossValueChangesPixels` (800×900 face box on 6000×4000: values 2,3,4,5 give 4 different images); `testBlocksAcrossNeverFinerThanFloor` (block side ≥ shorter side / 5); `testOldFixedBlockSizeDecodes` (old JSON with `"blockSize": 16` → same pixels as before this change); `testRoundTripRelative`.
- [ ] Implement, editor labels "Coarse" / "Fine" with the number, hover help; docs; commit `fix(redact): relative block size and strength that change on every image`.

### Task 4: Exclusive commits and long names (bugs B1 HIGH, B3/E4 LOW)

**Files:** `FileCommitter.swift:36` (+ `commitVariants`, `JobRunner.writeReport`), `OutputPlanner.swift:156, 167, 173-176, 229`, new `Sources/ImageconverterCore/PlannedDestinations.swift`, tests `ExclusiveCommitTests.swift`, `LongNameTests.swift`.

**Interfaces — Produces:** `enum PlannedDestinations { static func claim(_ url: URL) -> Bool; static func release(_ url: URL) }` (process-wide, keyed by `FileIdentity.pathKey`, lock-protected); `FileCommitter.commit` returns the URL actually written (`@discardableResult`).
- [ ] Failing tests: `testConcurrentRunsNeverReplace` (the bug report's repro: two `BatchRunner.run` at once, 6 same-named PNGs each, one `.newFolder` → 12 distinct files, all reported paths exist with their own content, 20 rounds); `testCommitTakesNextFreeNameWhenTaken` (a file appears at the planned name after planning → written as `_2`, report shows the real name); `testOverwriteNeverTrashesWhenReplaced`; `testLongSourceNameIsShortened` (249-byte name, same-folder suffix → written, name ≤ 255 bytes UTF-8, cut on a character boundary); `testSuffixDropsZeroWidthAndBidi`.
- [ ] Fix: final step `renamex_np(temp, dest, RENAME_EXCL)`; on `EEXIST` re-pick the next free `_n` (claimed in `PlannedDestinations`) up to 1000 tries, then fail; planner claims destinations for the run and releases them when the item finishes; main-output names fitted to 255 bytes like `OutputPlanner+Variants.fitted`; suffix sanitised (drop `\u{200B}-\u{200F}`, `\u{202A}-\u{202E}`, `\u{2066}-\u{2069}`, `\u{FEFF}`).
- [ ] Docs (README "Never loses files" note), CHANGELOG; commit `fix(files): exclusive commits, concurrent runs never replace each other; long names shortened`.

### Task 5: Redact and focus detection run once (bug F2 / Johan's report)

**Files:** `RedactDetector.swift:39-54` (`RedactCache`), `FocusDetector.swift` (`FocusCache`), preview status, tests `DetectionCacheTests.swift`.
- [ ] Failing tests: `testConcurrentLookupsShareOneDetection` (fake detector counting calls with a 200 ms delay; preview + estimate + ladder lookups at once → 1 call); `testCancelledFirstCallerDoesNotCancelWaiters`; `testFailureIsNotCachedAndWaitersGetIt`.
- [ ] Fix: in-flight `Task` per key in both caches; waiters await it; the task is detached from any single caller's cancellation (cancelled only when every waiter cancelled); failures not kept.
- [ ] Preview shows "Finding faces and text…" while a Redact detection runs (Låda Glass progress style, in the preview status line).
- [ ] CHANGELOG; commit `perf(redact): one detection per image shared by preview, estimate and ladder`.

### Task 6: Faster selection and preview (bugs G: 5, 6)

**Files:** `AppModel+Preview.swift:96`, `AppModel+Estimate.swift:67`, `ImageconverterApp.swift:41-44`, `PreviewRenderer.swift:183, 276-304`, `SizeEstimator.swift:93-98`, new `Sources/ImageconverterCore/PreviewProxy.swift`, tests `PreviewProxyTests.swift`, `PreviewTimingTests`-style unit tests with injected clocks.

**Interfaces — Produces:** `extension Pipeline { public var isScaleInvariant: Bool }` — true only when every enabled step is in this allowlist: Adjust with `sharpness == 0`, or `sharpness < 0` only if `softenRadius` scales with the image size (implementer checks; if it doesn't, soften is not invariant); Color (profile, re-color; **not** reduce colours); rotate/flip 90° without angle; Resize percentage/fit/long edge (not exact pixel fill/pad), Trim off, no Crop/Canvas/Perspective/Watermark/Redact/conditions; Metadata/Rename (no pixels).
- [ ] Failing tests: `testSelectionRendersWithoutDebounce` (selection change schedules the render with 0 delay; a pipeline edit keeps 300 ms; estimate 0 / 400 ms); `testProxyUsedOnlyForScaleInvariant`; `testProxyNeverFinalForPixelUnitSteps` (Review Focus 1: the final preview image for a crop-px pipeline equals the batch result downscaled with the same `fit`); `testProxyFollowedByExactRender` (invariant pipeline: first result flagged `isProxy`, then the exact one replaces it); `testEstimateReusesPreviewDecode` (decode counter: one full decode for preview + estimate of the same item version).
- [ ] Fix: no debounce when the selected item changes (pipeline edits keep 300/400 ms); for a scale-invariant pipeline, render a proxy decoded at display size (≥ 1600 px long side, JPEG rounded up to source/2^k) first, show it, then render exactly at full size and replace it (the exact render is skipped while a slider is being dragged and runs 300 ms after the last edit); the size estimate takes the preview's full-size decoded source from the renderer's cache instead of decoding again (`SizeEstimator.swift:97-98`), and decodes downsampled only once.
- [ ] CHANGELOG ("Previews show sooner"); commit `perf(preview): no delay on selection, quick proxy for scale-invariant pipelines, shared decode with the estimate`.

### Task 7: Decode and small speed fixes (bugs G7, G21 perf, C2)

**Files:** `Pipeline+DecodeHint.swift:55`, `ImageLoader.swift:93`, `AppModel.swift:194-212`, `SidebarView.swift:193-195`, `ImageOps.swift:76-84`, tests.
- [ ] Failing tests: `testDecodeHintRoundsToPowerOfTwoFraction` (48 MP 8000×6000, target 2048 → maxLongSide 4000 (source/2), never between source/2 and source; target 900 → 2000 (source/4); still ≥ 2 × target); `testHeicThumbnailUsesEmbedded` (options include `kCGImageSourceCreateThumbnailFromImageIfAbsent`, not `…Always`, for thumbnails ≤ 512 px); `testAddManyFilesIsOneUpdate` (adding 5000 URLs mutates `items` once); `testClearCancelsPendingAdd`; `testAddDuringRunIsQueued` (ruling: an add that completes during a run is appended after the run ends, with a toast); `testColorProfileSkipsRedrawWhenAlreadyTarget` (sRGB 8-bit input, profile sRGB, no re-color/reduce → the same `CGImage` instance returned).
- [ ] Implement; CHANGELOG; commit `perf: faster downsampled JPEG decode, HEIC thumbnails, adding many files; Clear cancels a pending add`.

### Task 8: Untrusted input and metadata fixes (bugs E1, E2, E3, A2)

**Files:** `Conditions.swift:197-200`, `ConditionalActions.swift:6, 37`, `PrivacyScanner.swift:179-188`, `MetadataOverrides.swift:323`, `MetadataFields.swift:96`, `MetadataOps+XMP.swift` (`syncIPTC`), `RenameTemplate.swift:256-266`, tests.
- [ ] Failing tests: `testDeeplyNestedConditionIsRefusedNotCrashing` (60 levels, decoded on a 512 KB-stack `Thread` → throws or drops the nested step, no crash; one level of condition still loads); `testPrivacyFindsXMPLocationCreatedGPS` (XMP `Iptc4xmpExt:LocationCreated` with `exif:GPSLatitude`/`GPSLongitude` → a location finding with the values; the suggestion removes it); `testRemoveGPSAlsoRemovesXMPLocations`; `testNoncharactersStripped` (title with U+FFFE/U+FFFF → XMP parses, the other fields survive; same through `syncIPTC`); `testTwoEmptyTokensKeepOneSeparator` (`{date}_{camera}{lens}_{counter:00}` with no camera/lens → `1970-01-01_07`; `{date}{camera}_{counter}` → `1970-01-01_7`; an empty token first still drops its following separator).
- [ ] Fix per bug entries (nested conditions refused at decode time before decoding their content: a conditional step inside a branch is skipped with a `PipelineLoadNotes` note; remove XML-illegal characters: noncharacters `U+FFFE`, `U+FFFF`, `U+FDD0–U+FDEF`, and any `…FFFE/FFFF` plane noncharacter).
- [ ] CHANGELOG; commit `fix: refuse nested conditions on load, GPS in XMP locations, XML-safe metadata, rename separators`.

### Task 9: App state, quitting and Shortcuts (bugs C1, B2, C3, C4, C5, D1)

**Files:** `AppModel+Privacy.swift:77-83, 114-119`, `AppModel+Estimate.swift:53-54`, `MetadataInspector.swift:49`, `AppModel.swift:307-318`, `Intents/AutomationRuns.swift:18-31`, `Intents/IntentSupport.swift:38-65`, `BatchResourceLimits.swift`, `JobsController.swift:250-254`, `JobsController+Waiting.swift:15-38`, `QuitCoordinator.swift:22-26, 61-81`, `AppModel+Performance.swift:118-121, 178`, tests (logic pulled into Core or small testable types where needed).
- [ ] Failing tests: `testOverwriteRunRefreshesPrivacyEstimateAndMetadata` (keys include the file version (`FileIdentity` + modification date/size), so a rewritten file is re-read); `testShortcutsActionsRunOneAtATime` (three actions → batches never overlap; FIFO; each still returns its own files); `testRunJobWaitersAnsweredOnQuit` (waiter gets a "imageconverter is quitting" error); `testActionRefusedWhileQuitting`; `testResumeKeptWhenStartRefused` (`.noAccess` / `.busy` → interrupted run kept, a toast says why); `testQuitWaitsForInstall` (`anythingRunning` true while installing; quit asks like a running batch, and "Quit anyway" is not offered while the installer service is swapping).
- [ ] Implement; CHANGELOG; commit `fix: fresh data after overwrite runs, Shortcuts actions one at a time, clean quits`.

### Task 10: Installer note and command line (bugs D2, D3, D4, D5)

**Files:** `Sources/ImageconverterInstallerKit/InstallerService.swift:128`, the XPC reply and `UpdateController` (show the note), `Sources/ImageconverterCLI/main.swift:8-11`, `CLIOutput.swift`, `CLIParser.swift:43-51`, `CLIParser+Variant.swift:41`, tests in the installer and CLI test targets.
- [ ] Failing tests: `testSwapNoteIsReturned` (old app not removable → reply carries the note; the app shows it in the update sheet); `testSigtermAndSighupCancelLikeSigint` (signal handler set covers SIGINT, SIGTERM, SIGHUP; a second signal exits at once with 130); `testDoubleDashEndsOptions` (`jobs run -- -weird` runs job "-weird"); `testVariantQuotedValueWithComma` (`--variant 'folder="/a,b",format=png'` → folder `/a,b`; `\,` escape also accepted).
- [ ] Implement; README CLI section; CHANGELOG; commit `fix(cli,installer): SIGTERM/SIGHUP clean up, -- and quoted variants, swap note shown`.

### Task 11: Output 1 card (Johan's request)

**Files:** `PipelineSection.swift:295-330` (`OutputPanel`), `OutputVariantsSection.swift` (reuse `VariantPanel`'s card look), `OutputPanelHandle.swift` (`OutputSummary`), `OutputPanelState` (persist `mainOutputExpanded`, default true), tests for `OutputSummary` text.
**Ruling:** always a card (also with one output): heading "Output" with the "+" at the top right, then an "Output 1" card (same `AccordionCard`, title "Output 1", summary line format · quality · Save to) holding the format controls with the ⓘ and Save to; no remove button and no suffix/resize fields (the main output has neither); extra outputs below as "Output 2", "Output 3", … (their default names follow the card numbering); "When finished" stays under the cards (whole run). Collapsed panel (grab handle) unchanged.
- [ ] Failing test for the summary/name numbering (`testExtraOutputDefaultNamesStartAtTwo`), then UI, README screenshot text, CHANGELOG; commit `feat(output): every output is a card under the Output heading`.
