# Feedback Round 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Johan's 13-item feedback list of 2026-11-16 (quoted verbatim at the bottom), built as 8 tasks.

**Architecture:** Each task follows the existing split: logic in `ImageconverterCore` (pure, tested), UI in `Imageconverter`, docs updated in the same task. Lenient decoding for every saved-format change.

**Tech Stack:** Swift / SwiftUI, macOS 14+, Apple frameworks only; App Intents (Task 8) via an Xcode build.

**Spec:** Johan's list below plus his answers of 2026-11-16 (marked "(Johan)"): Shortcuts through real App Intents with an Xcode build; metadata panel edits apply to the outputs only, originals never touched; re-color = tint/monochrome + replace a colour + hue shift.

## Global Constraints

- Never edit `Sources/Imageconverter/DesignSystem/LadaGlass.swift`; Låda Glass components only; keyboard accessible; English.
- Never lose files; originals never modified (metadata panel included) (Johan).
- Saved pipelines/presets/jobs: new fields decode leniently, old files load unchanged; round-trip tests.
- Preview, size estimate, batch, jobs, CLI share one Core path.
- CI is macos-15 (Xcode 16): long `[UInt8]`/literal `+` chains in tests must use `concat(...)` (Tests/ImageconverterCoreTests/Support/ByteConcat.swift); any macOS 26/27 code stays behind the existing compiler guards. Check `gh run list` is not needed by implementers (no pushing), but code must compile with Swift 6.0.
- Hover help (`StepHelp`), README how-to + settings, CHANGELOG Unreleased, CLAUDE.md layout updated per task.

## Review Focus

1. Old presets/jobs with changed steps (Color profile, Perspective, Adjust sharpness, extra outputs) load and behave as before.
2. Metadata overrides from the panel never reach the original file and are clearly per-image.
3. Extra outputs with their own folders: sandbox access asked per folder; never writes into a source folder in place; collisions `_2`.
4. App Intents run with no UI in the background (sandbox access, missing preset names, empty input) and report errors in Shortcuts.
5. Redact text: images where detection used to miss text now get covered, or fail closed.

---

### Task 1: Quick UI items
- Previews default to **Split** comparison mode (new installs and a reset; existing users' saved choice kept).
- **Grab handle above Output**: a Låda Glass grab handle (like `EdgeHandle`) on the Output panel's top edge: a click toggles the Output panel collapsed/expanded (collapsed shows one summary line: format · quality · Save to); a drag resizes the Output panel vertically (min = its collapsed height, max = its full content; the steps area above gives way). Persisted (`outputCollapsed`, `outputHeight`). Works with `SidebarMotion` (height changes animated as today).
- **Rename**: more insert options in the token menu — at least: date taken (with formats), date modified, file created, camera make/model, lens, ISO, focal length, width/height/megapixels, orientation, original extension, parent folder name, preset name, `{labels}` (from 1.3), random 4/8 characters, UUID; and the **counter gets a step** (`{counter}` start, step (default 1, may be > 1, not 0), padding). Tokens sanitised as today.
Files: `PreviewPane`/`CompareController`, `OutputRow`/`SidebarView`/`WindowSizer*`, `RenameTemplate`/`RenameRendering`/`RenameEditor`, tests.

### Task 2: Adjust — soften/sharpen and presets
- Replace the Sharpness slider with **Soften ↔ Sharpen**: bipolar −100…100, 0 in the middle; right sharpens (existing sharpening), left softens (Gaussian/noise-reduction blur scaled with image size). Old saved `sharpness` values map to the positive side unchanged.
- **Adjust presets**: a menu in the Adjust editor: built-in looks + "Save current as…", rename, delete (store like watermark/metadata templates, `TemplateStore`, `adjust-presets/`). Built-ins (original names; generic looks inspired by common phone/social filters, no brand names): Vivid, Vivid Warm, Vivid Cool, Dramatic, Dramatic Warm, Dramatic Cool, Mono, Silvertone, Noir, Fade, Film, Golden Hour, Cool Breeze, Matte, Punch, Soft Portrait — each a fixed `AdjustOptions` set (document values in a table in README). Applying a preset sets the sliders (the step stays editable).
Files: `Adjustments`, `AdjustEditor`, new `AdjustPresets` (+ store/menu like `WatermarkTemplates*`), tests (old JSON, presets round-trip, soften changes pixels, 0 = identity).

### Task 3: Color step — re-color and reduce colours
- The **Color profile** step becomes **Color** (display name; JSON kind stays `colorProfile`, old files decode to profile-only). Sections: Profile (as today, optional "keep"), **Re-color** (Johan): none / Tint (monochrome in one colour with strength) / Duotone (shadows colour + highlights colour) / Sepia / **Replace colour** (source colour picked by colour well, tolerance %, softness, target colour; works in hue/chroma space) / **Hue shift** (−180…180°). **Reduce colours**: off / N colours (2–256) with dithering on/off (median-cut or k-means palette on a ≤ 512 px sample, then map full image; PNG/GIF output writes indexed when possible).
Files: `ImageOps` colour, new `Recolor`, `ColorReduce`, `StepEditors`, tests.

### Task 4: Perspective — keep size and fill the void
- Options: **Output size**: Fit corrected image (today) / **Keep original size** (scale the corrected image back to the source dimensions, aspect kept, centred). **Empty areas**: Crop to the image (today's behaviour if that's what it does — check) / Fill with colour / Transparent (alpha; formats without alpha get the colour with a note) / Extend edges (clamp).
Files: `Perspective`, `GeometryEditors`, tests.

### Task 5: Redact — pixel size and text reliability
- **Pixel size** control for Pixelate (and blur strength for Blur): Auto (today's scaling) or a fixed size in px / % of box.
- **Text detection reliability** — use superpowers:systematic-debugging: build a test corpus (`scripts/make-sample-images.swift` or test fixtures): small text, large text, light-on-dark, low contrast, rotated ±15°/90°, curved/stylised, handwriting-like, dense paragraphs, single digits, licence-plate-like, text on photos. Measure which are missed now, find root causes (recognition level fast vs accurate, `minimumTextHeight`, language correction, 2048 px cap, `VNDetectTextRectanglesRequest` options `reportCharacterBoxes`, orientation, tiling large images), fix, and add the corpus as regression tests (skip on CI only if Vision returns nothing at all).
Files: `VisionDetector`, `Redact*`, `RedactEditor`, tests.

### Task 6: Output panel redesign
- Each extra output is a **full copy of the Output panel** (format, compression, quality/target/smart, progressive, PNG optimisation, resize, name suffix, **its own Save to** (same modes as the main output: new folder / same folder / … — but never overwrite in place, Global Constraint), When finished stays global). "+" button (icon only, accessible label "Add output") at the **top right of the Output panel**; each extra panel has a remove button and a name. The size-saving text moves into a hover box behind an **ⓘ** icon right of the format picker (all outputs' sizes listed there). Model: `OutputVariant` gains `destination` (optional; nil = beside the main output as today); folder access per destination (AccessStore). Old JSON decodes unchanged.
Files: `OutputRow`, `SaveToControl`, `OutputVariant`, `OutputPlanner`, `AccessNeeds`, tests.

### Task 7: Metadata side panel and privacy links
- A collapsible **right panel** (closed by default, toggle in the toolbar/View menu, ⌥⌘I) showing the selected image's metadata grouped (File, EXIF, GPS, IPTC, XMP, TIFF, maker summary), searchable. **Edit, remove, add** fields → stored as **per-image metadata overrides** applied to that image's outputs only (Johan), shown with a badge in the filmstrip/list and in the panel ("Changes apply to the output"), revertible per field and per image; persisted with the batch session only (cleared when the image is removed). Applied after the Metadata step (overrides win; removals in the Metadata step's floor still apply unless the user explicitly re-adds that field — say so). Uses the existing allowlisted field model (`MetadataFields`), untrusted values sanitised.
- **Privacy scan findings**: each finding shows the identified values (e.g. the GPS coordinates, the serial number, the author name) and a link per image; clicking selects that image, shows it in the preview and opens the right panel scrolled to that field.
Files: new `MetadataInspector*` views, `AppModel+MetadataOverrides`, Core `MetadataOverrides`, `PrivacyPanel`, `PrivacyScanner` (values), batch apply, tests.

### Task 8: Shortcuts (App Intents), and validating the CLI and AppleScript
- **Build**: move the app's release build to `xcodebuild` (an Xcode project or the package scheme — whichever makes App Intents metadata (`Metadata.appintents`) land in the bundle; no third-party generators) while keeping `swift build`/`swift test` working for development and CI. `scripts/release.sh` signs/notarizes as today and verifies `Contents/Resources/Metadata.appintents` exists.
- **Intents** (App Intents, macOS 14+): Convert Images (files in, preset by name (entity with suggestions), output folder optional, returns output files), Apply Preset to Folder, Run Job (entity), Strip Metadata (files in, files out), Resize Images (long edge), Convert Format (format, quality), Get Image Metadata (returns text), plus App Shortcuts phrases. Run in the background without UI where possible; sandbox: files passed by Shortcuts are accessible; folders need an existing grant or an error explaining Folder Access.
- **Validate** end to end, with evidence in the report: the CLI (`convert`, `presets list`, `jobs run`, `--dry-run`, `--variant`, errors/exit codes) from the bundle's `Contents/Helpers/imageconverter`; AppleScript (the sdef commands via `osascript` against the built app — note macOS may ask for Automation permission; if blocked, say exactly what Johan must allow); Services; and Shortcuts (`shortcuts run` CLI with a test shortcut if one can be created programmatically, else a documented hand test). Fix what's broken.
Files: build scripts, `Sources/Imageconverter/Intents/*`, Info.plist fragments, README "Automate with Shortcuts, AppleScript and the command line", tests for intent logic in Core.

## Johan's list (verbatim, 2026-11-16)

- Adjust size of pixels when using the redact pipeline
- Reda t pipeline for text does not work all the time
- Add a collapsable right panel, that shows the meta data of the selected image, the user also has the ability to edit, remove and add metadata. The panel is closed by default
- When the app warns for metadata when doing the privacy scan, show the data that was identified, also add a link to the metadata, when clicking on the link, the metadatas inages is selwcted and displayed, and the rightsided panel is opened.
- In the perspective pipeline item, add the option to not resize the image, also add options to handle the void, replace with color, transparent etc
- Add the ability to save preset for the adjust pipeline item, then add some default presets/filters, get insperation from diffrent social media platforms filters and iphone camera filters.
- For the adjust pipeline item, change the sharpes adjustmen, make it softwn/sharpen instead, the slider is in the middle draging it to the right makes the image sharper, draging it to the left makes the image softer.
- For the rename pipline item, add more insert options, for count also add step.
- Make the previews default to be split
- For the color pipeline item add a re-color option, add a option to reduce colors used
- Add a grabhandel above the output, vlicking on it once will collaps it, click n drag will resize it verticly.
- I cant get the shortcut function to work, and i dont see any items from the app in apple shortcuts, validate that the shortcut function works as expected, the user should be able to use the apps functions using shortcuts. Alos validate that the cli and apples ript integration works as expected
- The output module is a bit confusing when addinge more outputs. Remake it, so when clicking on add output it just adds the same panel as the original output panel, so the user can both have custom fileformats and config and diffrent output paths. Move the + add output button to the top right of the output panel and just use the + not the text. Then move the text about how much size is saved with the new settings move that text to a hover box, the i icon that triggers the box is on the rightside of the format dropdown.
