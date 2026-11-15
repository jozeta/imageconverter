# Vision Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five on-device AI features Johan picked from research section 16 of `PRODUCT_RESEARCH_AND_FEATURE_ROADMAP.md` (items 2–6): smart crop, AI conditions + keywords, a Redact step, ML enlarge, alt text.

**Architecture:** Each feature is Core logic (pure maths + Vision/VideoToolbox/FoundationModels calls behind small protocols so tests can inject results) plus app UI in the existing step editors, conditions and Metadata step. Everything on-device.

**Tech Stack:** Swift 5.10 package, macOS 14 deployment target, Vision, Core Image, VideoToolbox (macOS 26+), FoundationModels (macOS 27+).

**Spec:** the research (section 16 of the roadmap file, untracked, in the repo root) and the decisions below, agreed with Johan 2026-11-15 ("do 2,3,4,5,6"; design calls stated to him in chat).

## Global Constraints

- Deployment target stays macOS 14. Newer APIs behind `@available` + runtime checks; the UI hides or disables options the OS can't do, with a one-line reason ("Needs macOS 26 or later").
- CI runs on `macos-15` (Xcode 16 SDK): code using macOS 26/27 SDK symbols must be compiled conditionally (`#if canImport(...)` and/or `#if compiler(>=…)`, whichever actually works — verify with `swift --version` and the SDKs) so CI builds and tests pass there; local Xcode 27.2 builds everything.
- Apple frameworks only; no bundled models. Images and metadata stay untrusted; Vision runs on a downsampled decode (≤ 1024 px long edge) unless a feature needs more, and respects `DecodeLimits`.
- Vision results never fail a run: errors → a per-item note, the item continues (best effort).
- Preview, size estimate, batch, jobs and CLI use the same Core path (the existing rule).
- Presets/pipelines: new options decode leniently (absent → today's behaviour); round-trip tests.
- Every new step/option gets hover help (`StepHelp`), README how-to + settings, CHANGELOG Unreleased, CLAUDE.md layout. English only.
- Privacy wording (README, PrivacyStatement, SECURITY.md) updated only where behaviour changes (feature 5's model download).

## Feature decisions (binding)

1. **Smart crop:** a Focus setting on Crop (both modes) and on Resize › exact size › Fill and crop: `.anchor(Anchor)` (today, default centre) | `.subject` (Vision attention-based saliency ∪ objectness boxes, top salient regions) | `.faces` (union of face rectangles; falls back to subject, then centre). The crop window centres the focus rect, clamped inside the image; if the focus is larger than the window, keep the window centred on the focus centre. Pure geometry in Core with the focus rect injected for tests; a thin `FocusDetector` does Vision.
2. **AI conditions + keywords:** new condition checks: *Shows* (any/all of labels, Vision `VNClassifyImageRequest`, confidence ≥ 0.3 default, picked from a searchable label list), *Face count* (op N), *Contains text* (yes/no, `VNRecognizeTextRequest` fast level), and on macOS 15+ *Aesthetics score* (op x, −1…1) and *Screenshot or document* (`isUtility`). On macOS 14 the macOS 15 checks don't match and add a note once per run. Facts computed lazily via `FactNeeds`, cached in `ItemFactsCache` per file version. New token `{labels}` (top labels ≥ threshold, comma-joined, max 10, sanitised) usable in keyword, Finder tag, subfolder and note templates.
3. **Redact step:** new pipeline step "Redact" (inserted after Crop/Rotate in the default order, reorderable): targets faces / text / both; style blur (default), pixelate, solid fill (colour); padding % (default 15). Detection on the image as it arrives at the step. Report note per item ("Redacted 2 faces, 1 text area") and "best effort — check the results" in the editor and README. Privacy panel: an opt-in "Also look for faces and text" toggle (off by default, persisted) that adds findings and suggests adding the Redact step; never automatic.
4. **ML enlarge:** Resize mode "Enlarge with machine learning" with factor 2×/3×/4× (macOS 26+). Uses VideoToolbox's super-resolution scaler in its image mode (4×, ≤ 1920 px per input side): tile the input with overlap and feathered blending, run 4×, then downsample to 2×/3× with Lanczos. Output must stay within `DecodeLimits` pixel cap (refuse with a note otherwise). Model availability: if the system reports the model must be downloaded, the app asks once ("macOS will download Apple's enlargement model from Apple. imageconverter itself sends nothing.") and starts the system download; the answer is remembered. Jobs, CLI, Services and scripts never trigger the download: items are skipped with "ML enlarge model not installed" (counted as failures). Privacy statement and README updated accordingly.
5. **Alt text:** Metadata step option "Generate alt text on this Mac" (macOS 27+, needs Apple Intelligence and the on-device model ready; otherwise disabled with the reason). Uses `SystemLanguageModel` on-device only (never Private Cloud Compute) with the image attachment; prompt asks for concise alt text (≤ 250 chars, English, no "image of"). Output is untrusted: strip control characters, collapse whitespace, cap 250 chars. Written to XMP `Iptc4xmpCore:AltTextAccessibility` (lang-alt x-default) and, if the user ticks it, `dc:description`. Model unavailable at run time → note, item continues without it. Preview shows the generated text for the selected image.

## Review Focus

1. Images with nothing detected (no faces, no salient object, no text) → today's behaviour, no crash, a note where useful.
2. Huge images (100 MP+) through Vision and ML enlarge → downsampled detection, tiled enlarge, memory within `WorkWindow`.
3. Running on macOS 14 with presets that use macOS 15/26/27 features → clear notes, nothing crashes, options shown disabled.
4. Redact geometry after Rotate/Crop/Resize earlier in the pipeline → boxes land on the right pixels (detection on the image at the step).
5. Model-generated text (labels, alt text) used in file names/metadata → sanitised like other untrusted text.

---

### Task 1: Smart crop
Files: Core `Geometry` (+ new `CropFocus`, `FocusDetector`), `ImageOps` crop/resize fill path, `Pipeline` decoding, app `GeometryEditors.swift`, `ResizeEditor.swift`, `StepHelp`, docs. Tests: geometry with injected focus rects (focus at edges, larger than window, none), decode/round-trip, one Vision integration test on a generated image with a single high-contrast object (skip with XCTSkip if Vision returns nothing on CI).

### Task 2: AI conditions and `{labels}`
Files: Core `ItemFacts`/`ItemFacts+Vision` (new), `FactNeeds`, `ConditionCheck`, `ConditionValues`, `ConditionSummary`, `ItemFactsCache`, token rendering in `SubfolderTemplate`/keywords/tags/note; app `ConditionKind`, `ConditionValueControls` (label picker); docs. Tests with an injected `VisionFacts` provider; label sanitising; macOS-15-only check behaviour on 14 via availability seam.

### Task 3: Redact step
Files: Core `Redact` (options, geometry: normalized Vision boxes → pixel rects with padding, clamped), `ImageOps+Redact` (blur/pixelate/fill via Core Image, only inside the rects), `Pipeline` step kind, `StepSummary`, `StepHelp`, `PrivacyScanner` opt-in content findings; app editor + Privacy panel toggle; docs. Tests with injected detections (pixels inside changed, outside identical), orientation/pipeline-order test, round-trip.

### Task 4: ML enlarge
Files: Core `ResizeModel` (new mode), `MLEnlarge` (tiling plan pure + VideoToolbox runner behind a protocol), `Geometry` plan, `DecodeLimits` check, model-availability seam; app `ResizeEditor` + one-time download consent; CLI/job/service refusal; PrivacyStatement, README, SECURITY.md; docs. Tests: tiling plan (overlaps, edges, sizes 1…1921…8000), blending seams with a fake 4× scaler (nearest), refusal paths, availability gating. Controller runs one real enlarge locally if the model is present.

### Task 5: Alt text
Files: Core `MetadataOptions` (+ alt-text option), `MetadataOps+XMP` (AltTextAccessibility lang-alt, description), `AltTextGenerator` (protocol + FoundationModels implementation, compiled conditionally), sanitiser; app `MetadataEditor` option + availability reason, preview display; docs. Tests: XMP written and read back, sanitiser, unavailable path with a fake generator, lossless metadata path (Task A of 1.1) still verifies with the new field.
