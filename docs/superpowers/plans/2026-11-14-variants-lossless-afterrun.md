# Feature round: lossless metadata edits, after-run actions, output variants

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Johan picked items 2, 9 and 1 from PRODUCT_RESEARCH_AND_FEATURE_ROADMAP.md (2026-11-14): metadata-only changes without re-encoding, actions when a run finishes, and several outputs per image in one run.
**Architecture:** Core first (planner, encoder paths, report), then app UI; one shared plan/encode path keeps batch == estimate == CLI dry-run == jobs.
**Tech Stack:** Swift 5.10 SwiftPM, ImageIO (`CGImageDestinationCopyImageSource`), SwiftUI, UserNotifications.
**Spec:** docs/superpowers/specs/2026-11-13-imageconverter-design.md + the research report's sections for items 1, 2, 9.

## Global Constraints
- Apple frameworks only; never lose files (FileCommitter/Trash rules, overwrite semantics); metadata removals are a floor; estimate == batch; old saved pipelines/presets/jobs decode unchanged (lenient).
- 0 warnings (fresh build), all tests green, `swiftlint --strict` 0, shellcheck clean. Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; author email is the global noreply default; stage only your files; never push.
- Version: next push is a minor bump (1.1.0) — not part of these tasks.

## Review Focus
1. A lossless metadata edit must never leave a removed field in the output (verify by rescanning; fall back to re-encode if the lossless path can't guarantee it).
2. Variants in overwrite mode must never replace or trash the original twice, and extra variants must never replace any existing file.
3. Estimate, preview names, CLI dry-run and job ledgers must list every variant.

---

### Task A: Lossless metadata-only edits
**Files:** Core `ImageEncoder.swift`/`BatchRunner.swift` encode path (+ new `LosslessMetadata.swift`), `MetadataOps*`, `SizeEstimator`, tests.
- When the effective (resolved) pipeline for an item has no pixel-changing steps (no image steps, no watermark, output format == source format, no resize-by-condition, compression mode `.quality` at the "faithful"/keep setting or a new explicit "Keep original quality when only metadata changes" behaviour — define: if no pixel step is active AND the output format equals the source's format, take the lossless path regardless of the quality slider; document it), write with `CGImageDestinationCopyImageSource` + the metadata changes (`kCGImageDestinationMetadata`, `kCGImageDestinationMergeMetadata`, orientation untouched — note: "photos saved upright" rule: if the source has a non-1 EXIF orientation, the lossless path keeps the orientation flag instead of rotating pixels; that is correct for a lossless copy — document) for formats ImageIO supports this for (JPEG, PNG, TIFF, PSD; check HEIC/AVIF — if unsupported, fall back to the current re-encode with a report note "re-encoded: lossless metadata edit isn't available for this format").
- After writing, re-read the result with `PrivacyScanner`/property checks: if any field the options remove is still present, discard that result and fall back to the re-encode path (note "lossless edit couldn't remove …; re-encoded").
- Applies to the batch, conditions' copyOriginal-with-removal (`convertedForPrivacyNote` path), the Privacy panel's "Remove these" runs, the CLI, jobs; the size estimate uses the same decision (estimate == batch).
- Tests: pixel data byte-identical (JPEG scan data unchanged) after GPS removal; file not larger than original + metadata delta; removal verified; unsupported format falls back with the note; orientation flag preserved; floor still holds.

### Task B: After-run actions
**Files:** app `AppSettings`/Output panel or a small "When finished" control, `AppModel` finish, `JobNotifier` reuse, README.
- Setting "When a run finishes": Nothing (default) / Reveal outputs in Finder / Notify me / Reveal and notify. Reveal: `NSWorkspace.shared.activateFileViewerSelecting(outputs)` (up to 50 files; if more, reveal their folders). Notify: a local notification ("Converted 24 images · saved 31 MB") only when the app isn't frontmost; ask permission on first enable; clicking it brings the window forward with the report. Applies to manual runs (and Services/AppleScript/URL-started runs); jobs keep their own notifications. Persisted per app (not per preset).
- Tests for the pure decision (which files/folders to reveal, notify-when-background rule).

### Task C: Output variants (several outputs per image)
**Files:** Core `OutputSettings`/new `OutputVariant`, `Pipeline`, `OutputPlanner`, `BatchRunner(+Schedule,+Conditions)`, `SizeEstimator`, `ProcessingReport`/`ReportExporter`, `ProcessedLedger`/`JobRunner`, CLI (`--variant`), app Output panel (`OutputPanel`/`OutputRow`), preview table, README/CHANGELOG; tests.
- Model: `Pipeline.output` stays the primary output. New `Pipeline.extraOutputs: [OutputVariant]` (max 8): `OutputVariant { id, name (label), settings: OutputSettings (format, quality, compression, progressive, optimizePNG), resize: VariantResize? (none / longest edge / max width / max height / percent — applied after the pipeline's own steps, shrink-only unless percent > 100), nameSuffix: String (default e.g. "_thumb", sanitised like rename suffixes), subfolder: String? (template, same rules as condition subfolders) }`. Lenient decode; presets/templates/jobs carry them.
- Processing: decode + pipeline (+ metadata) once per image; for each variant: optional resize of the processed image, then encode with that variant's settings (compression search per variant). Memory: weigh the extra resized copies in peakPixels; variants processed sequentially per image.
- Planning: the primary output plans exactly as today (all modes). Extra variants are always written as NEW files: in new-folder mode next to the primary (or its subfolder) as `<name><suffix>.<ext>`; in same-folder and overwrite modes in the source's folder as `<name><suffix>.<ext>` — never in place, never trashing anything; collisions `_2` per folder; the suffix is required (non-empty, distinct per variant) so a variant can never target the source or the primary output. Rename applies to the base name; conditions' `.output` override replaces only the primary; a new condition action "Skip extra outputs" for that image.
- Reports/ledger/estimate: each variant is its own entry (report rows grouped per source; ledger records every output; estimate shows "Primary 1.1 MB · Thumbnail 48 KB · AVIF 620 KB"); CLI `--variant "name=thumb,format=jpeg,quality=70,long=400,suffix=_thumb"` (repeatable) and dry-run lists all; failure of one variant doesn't fail the others (per-variant notes), but if the primary fails, extras are not written.
- UI: Output panel shows the primary as today plus "+ Add output" (variant rows collapsible like steps: name, format, quality/compression, resize, suffix, subfolder, remove); the size line lists every variant; the preview table's Result column shows the primary with a small "+2 outputs" chip listing them on hover.
- Tests: three variants written with correct names/sizes; overwrite mode with variants (original replaced once, extras beside it, nothing else trashed); collisions; suffix validation; condition skip-extras; estimate == batch per variant; job ledger records all outputs (second run processes nothing); CLI parse + dry-run; old JSON decodes.
