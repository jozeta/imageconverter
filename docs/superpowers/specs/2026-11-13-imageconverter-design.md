# imageconverter: design

Date: 2026-11-13 · Status: approved by Johan on 2026-11-13

Decisions are marked **(Johan)** when Johan made them in the brainstorm and **(Claude's call)**
when Claude chose a default that Johan hasn't confirmed yet. Everything else is left to the builder.

## Intent

A native macOS app for **batch image processing**: drop in a pile of images, describe what should
happen to them once, and run it over all of them. Format conversion is one job among several. The
others are resizing, cropping, watermarking, cleaning metadata and renaming. The app should read any
image format the Mac can read and write a handful of common formats.

It is for Johan first, and it is shared with others as a signed, notarized app **(Johan)**.

Why: the existing ways to do this on a Mac (Preview, Automator, Shortcuts, `sips`, web converters)
either do one thing at a time, can't be saved as a reusable recipe, or send files to someone
else's server.

## Goals

1. **Read every image format macOS can decode** (HEIC, JPEG, PNG, TIFF, GIF, BMP, WebP, AVIF,
   PSD, camera RAW, JPEG 2000, ICNS, …). Wide input matters more than wide output **(Johan)**.
2. **Write a few formats well**: JPEG, PNG, HEIC and TIFF, plus any of GIF, BMP and JPEG 2000 that
   ImageIO writes cleanly. The list is built at runtime from what ImageIO reports it can write,
   filtered by an allowlist in code, so AVIF/WebP appear later if macOS gains encoders, without new
   code paths **(Claude's call)**. No bundled third-party encoders in v1 **(Johan: few outputs is fine)**.
3. **A pipeline**: one run applies several operations to every image, in order **(Johan)**.
4. **Presets and one-off runs**: a pipeline can be saved as a named preset, or set up and run
   without saving **(Johan)**.
5. **Never lose the user's files by surprise** (see Anti-goals).

## Non-goals (v1)

- Per-image editing (adjusting one photo differently from the rest), filters, colour grading,
  RAW development controls. RAW files are decoded with the system defaults.
- Animated or multi-page output. Animated GIFs, multi-page TIFFs and HEIC sequences are read using
  their **first frame only** **(Claude's call)**.
- PDF or SVG input (they aren't raster images to ImageIO).
- A command-line interface, Shortcuts/Automator actions, a Finder extension. These are possible
  later.
- Swedish localisation: the app is **English only** **(Johan)**.
- Mac App Store distribution **(Johan: signed + notarized direct download)**.
- Any network access: no updates check, no telemetry, no cloud.

## Anti-goals (a failure even if it "works")

- An original file is destroyed or replaced without the user having chosen overwrite mode.
- A file is written half-finished (a crash or cancel mid-write leaves a corrupt file in place of a
  good one). Writes go to a temporary file and are moved into place atomically.
- Metadata the user asked to strip (e.g. GPS) still ends up in the output file.
- The UI freezes during a run.
- The app makes any network request.

## The pipeline

A pipeline is an ordered list of steps. Each step can be **turned off without deleting it** and the
image-changing steps can be **reordered by dragging** **(Claude's call; Johan didn't object)**.

### Image steps (reorderable, any number, each optional)

| Step | Settings |
|------|----------|
| **Resize** | Mode: max width · max height · max width *and* max height (fit inside the box) · exact width (height follows aspect) · exact height · exact width × height (with a choice: stretch, or fit and pad, or fill and crop). "Don't enlarge smaller images" toggle (on by default). **(Johan)** for the modes; the rest is Claude's call. |
| **Crop** | Fixed pixel size *or* aspect ratio (presets 1:1, 4:5, 3:2, 16:9, custom). Anchor: centre by default, 9-point choice. |
| **Rotate / flip** | Rotate 90° / 180° / 270°, flip horizontal / vertical. EXIF orientation is always applied first (images are normalised to "up" when read), so this step rotates what the user sees. |
| **Canvas / padding** | Add equal padding (px or %) *or* extend to a fixed canvas size; anchor; background colour (incl. transparent where the output format supports it). |
| **Color profile** | Convert to sRGB, Display P3, or Generic Gray; or keep the source profile. |
| **Watermark** | Text *or* image (PNG/any readable image) **(Johan)**. Position: 9-point grid + margin. Size: relative to the image (percent of the image's shorter side), so it looks the same across mixed sizes. Opacity 0–100 % **(Johan)**. Text: font, colour. |

### File steps (fixed position at the end, each optional)

These don't change pixels, so their order doesn't matter, and they're shown as fixed sections at the
bottom of the pipeline **(Claude's call)**:

| Step | Settings |
|------|----------|
| **Metadata** | Remove all · remove GPS/location · remove camera/device details · keep. Set or replace: artist, copyright, description. **(Johan: change/remove metadata)** |
| **Rename** | A pattern with tokens **(Johan: date, camera, counter, plus more such as metadata and size)**. See below. |
| **Output** | Format and its options: JPEG/HEIC quality, PNG (lossless, no setting), TIFF compression (none / LZW). Where the file goes is the global output mode (see "Output modes"), shown here for reference. |

### Rename tokens

`{name}` original name without extension · `{ext}` new extension · `{date}` capture date (EXIF
DateTimeOriginal, falling back to the file's creation date) with an optional format, e.g.
`{date:yyyy-MM-dd}` · `{time:HHmmss}` · `{camera}` model · `{make}` · `{lens}` · `{iso}` ·
`{width}` `{height}` output pixel size · `{format}` · `{folder}` source folder name · `{counter}`
with padding, e.g. `{counter:000}`, and a start number.

Metadata is untrusted input: token values are sanitised into safe filename characters (no `/`,
`:`, control characters, leading dots) and length-capped. Missing values become empty strings,
and a lone `_` or `-` left behind is collapsed. The UI shows a live example name for the selected
image.

## Output modes

A setting with three choices **(Johan)**:

1. **New folder**: the user picks a folder; outputs go there.
2. **Same folder, new name**: next to each original, using the rename pattern, or `{name}_converted` if no rename step is on.
3. **Overwrite originals**. If the output keeps the original's path (same name, same format), the
   file is replaced atomically. If the format or the name changes (e.g. `IMG_2041.HEIC` → JPEG, or a
   Rename step is on), the new file is written (e.g. `IMG_2041.jpg`) and the **original is moved to
   the Trash**, so it stays recoverable **(Johan)**. If the new name collides with another existing
   file, `_2`, `_3`, … is appended as usual. Existing unrelated files are never replaced.

In "new folder" mode, images from a dropped folder keep their **subfolder structure** under the
destination (subfolders are created as needed); loose dropped files go to the top level
**(Claude's call)**.

When the user *selects* overwrite mode, the app warns once, then and there, and asks them to
confirm. **It does not warn again when a run starts or while it overwrites** **(Johan)**.

Where the setting lives: **one global setting** in the Settings window, mirrored read-only in the
Output step's summary. It is **not** part of presets, so loading a preset can never switch on
overwrite silently, and the one-time warning always fires when overwrite is chosen **(Johan: "a
setting"; keeping it out of presets is Claude's call)**.

## Running a batch

**(Johan agreed to all of these.)**

- Images are processed in parallel, with concurrency bounded to keep memory in check. The UI stays
  responsive.
- A progress bar with a count ("57 / 124") and a Cancel button. Cancelling stops new work. Files
  already finished are kept, and a file being written is not left half-written.
- A file that can't be read or written is **skipped**, the run continues, and a summary at the end
  lists the failures with a reason.
- If two outputs would get the same name, or a file with that name already exists (outside
  overwrite mode), `_2`, `_3`, … is appended.
- Decompression-bomb guard: images above a pixel limit (default 250 megapixels) are skipped with a
  clear reason **(Claude's call)**.

## Main window (layout B, chosen by Johan)

```
┌ Sidebar ──────────────────────┐┌ Preview (collapsible) ─────────────────┐
│ Preset: Web export ▾  Save…   ││ before            │ after              │
│ ┌ Drop images or folders ───┐ ││                   │          © logo    │
│ │ 124 images · Clear        │ ││ IMG_2041.HEIC 4032×3024 →              │
│ └───────────────────────────┘ ││   2026-11-13_iPhone15_001.jpg 1600×1200│
│ Pipeline (collapsible) ▾      ││ [filmstrip of the batch]               │
│  ☰ Resize · max 1600 px       │└────────────────────────────────────────┘
│  ☰ Watermark · logo 20%       │
│  … Metadata · Rename · Output │
│ [ Run (124) ]                 │
└───────────────────────────────┘
```

- **Sidebar, top to bottom:** preset picker (choose, Save, Save as, rename, delete), then a **drop
  zone** for images and folders (folders are searched recursively for readable images; also an
  "Add…" button with an open panel), then the pipeline, then Run **(Johan)**.
- **The pipeline section collapses** to a one-line summary **(Johan)**.
- **The preview collapses** too, shrinking the window to just the sidebar **(Johan)**. When open, it
  shows the selected image before and after the pipeline (rendered at preview size, updating live
  as settings change), the old → new name and size, and a filmstrip of the batch.
- Clicking a step **expands its settings in place** in the list (an accordion) **(Claude's call)**.
- "+ Add step" offers the image steps. "Reset to preset" undoes unsaved changes.
- A Settings window (⌘,) holds the output mode and its default folder, and the "same folder"
  suffix. An About window shows the version.
- Keyboard: everything reachable by keyboard. ⌘O add images, ⌘R run, ⌘. cancel, ⌘S save preset.
  VoiceOver labels on all controls.
- Looks: Låda Glass (the vendored `LadaGlass.swift`), dark frosted glass by default, compact
  density, `lg-` components and tokens only.

## Presets

- Stored as JSON (Codable) in `~/Library/Application Support/imageconverter/presets/`, one file per
  preset, versioned (`"schemaVersion": 1`), so the format can be migrated later.
- Presets refer to files (watermark image, output folder) through security-scoped bookmarks.
- Loading a preset validates it, and an invalid or tampered file is rejected with a message, not
  crashed on.
- A few built-in starter presets (e.g. "Web export: max 2048 px, sRGB, strip GPS, JPEG 82 %")
  **(Claude's call)**.

## Tech

- **Swift + SwiftUI, macOS 14+, Swift Package Manager**, as scaffolded. No third-party
  dependencies in v1.
- **ImageIO** (`CGImageSource` / `CGImageDestination`) to decode, encode and read/write metadata.
  **Core Graphics** (`CGContext`) for resize, crop, rotate, canvas and watermark. **ColorSync /
  `CGColorSpace`** for profile conversion. Core Image only if it is clearly simpler for a step.
- **All logic in `ImageconverterCore`** (the pipeline model, each operation as a pure function
  `CGImage → CGImage` or metadata → metadata, rename templating, naming collisions, presets
  load/save, the batch runner). The `Imageconverter` target is views only. Tests cover each
  operation on small generated images, the rename tokenizer, resize/crop maths, collision naming,
  preset round-tripping and rejection of bad presets, and that stripped metadata is really gone from
  the written file.
- **Distribution:** a build script (`scripts/release.sh`) wraps the SwiftPM build into a `.app`
  bundle (Info.plist with the version from `VERSION`, icon), signs it with the Developer ID
  certificate (hardened runtime), notarizes with `notarytool` using a keychain profile, and staples
  it. Credentials live in the keychain only, never in the repo. Johan has a developer account **(Johan)**.
- **App Sandbox on** **(Johan)**, with only user-selected read/write file access and no network
  entitlement. Consequence: dropping *files* only grants access to those files, while "same folder,
  new name" and overwrite (temp file + atomic move, Trash) need access to the parent folder. Before
  a run starts, the app checks which folders it lacks access to and asks once per folder with a
  pre-filled open panel, then remembers each grant with a security-scoped bookmark. Dropping a
  *folder* needs no extra prompt. "Move to Trash" uses `FileManager.trashItem`.
- The version is shown in the About window, read from the bundle's `CFBundleShortVersionString`,
  which the build script fills from `VERSION`. `swift run` falls back to the `VERSION` file.

## Suggested build order (each step is a usable, tested increment)

1. Core pipeline model + convert: read anything, write JPEG/PNG/HEIC/TIFF with quality; batch
   runner with progress, cancel, skip-on-error, collision naming; output modes incl. the overwrite
   warning. Minimal UI: drop zone, output format, Run.
2. Resize, crop, rotate/flip, canvas, colour profile steps; the reorderable/toggleable pipeline UI.
3. Metadata step and rename step with the token language and live example.
4. Watermark (text + image).
5. Presets (save/load/built-ins) and the collapsible preview with filmstrip.
6. Packaging: `.app` bundle, signing, notarization, About window, README screenshots → 1.0.0.

## Left to the builder

Internal type names and file layout inside the two targets; the concurrency mechanism and memory
strategy (e.g. `CGImageSourceCreateThumbnailAtIndex` for fast downscaling); preview rendering and
debouncing; exact control choices inside each step's settings; app icon design; which LadaGlass
components to use where.
