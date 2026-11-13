# imageconverter

A native macOS app for **batch image processing**. Drop in a pile of images or folders, build a
pipeline once (resize, crop, watermark, clean metadata, rename, convert) and run it over all of
them. It reads every image format your Mac can decode and writes the common ones. Everything happens
on your Mac: no uploads, no network access at all.

For anyone who regularly prepares photos for the web, for sharing or for archiving, and is tired
of doing it one image or one operation at a time.

**Version:** 0.1.0 · **Status:** early development (milestone 1, batch conversion, works; the image steps resize, crop, rotate/flip, canvas and color profile, plus metadata and rename, are available; the watermark step is available; presets and the before/after preview are available).
Started 2026-11-13. The full design is in
[docs/superpowers/specs/2026-11-13-imageconverter-design.md](docs/superpowers/specs/2026-11-13-imageconverter-design.md).

## What's new

### Unreleased

- Presets (save, save as, rename, delete, reset; three built-ins) and a collapsible before/after preview with a filmstrip of the batch.
- Watermark step: text (font, colour) or image (e.g. a logo), with position, size relative to the image, opacity and margin.
- Metadata step (remove location, camera details or everything; set artist, copyright and description) and Rename step with tokens ({date}, {camera}, {counter:000}, …) and a live example.
- Wide-colour (Display P3) photos keep their colour when resized and saved as JPEG; opaque images stay opaque through steps; memory use accounts for enlargement.
- Pipeline steps: resize, crop, rotate/flip, canvas/padding and color profile; steps can be reordered, switched off and removed; the pipeline is kept between launches. Large images are scheduled by memory use; file types macOS can't read (e.g. SVG) are ignored when adding folders.

### 0.1.0

- Project created. Older versions are listed in [CHANGELOG.md](CHANGELOG.md).

## Features

- **Reads** every format macOS can decode: HEIC, JPEG, PNG, TIFF, GIF, BMP, WebP, AVIF, PSD, camera
  RAW, JPEG 2000, ICNS and more. Animated and multi-page files are read using their first frame.
- **Writes** JPEG, PNG, HEIC and TIFF, plus GIF, BMP and JPEG 2000 where macOS supports them, with
  quality and compression options.
- **Pipeline** of steps, applied in order to every image. Steps can be switched off and reordered:
  - (available) **Resize**: max width, max height, fit inside a box, exact width and/or height (stretch, pad
    or crop to fill), with "don't enlarge" on by default
  - (available) **Crop**: fixed size or aspect ratio, with an anchor point
  - (available) **Rotate / flip**
  - (available) **Canvas / padding**: with a background colour
  - (available) **Color profile**: convert to sRGB, Display P3 or Gray, or keep the original
  - (available) **Watermark**: text or image, with position, size, opacity and margin controls
  - (available) **Metadata** (always last, above Output): strip everything, location only or camera
    details, or set artist, copyright and description; the color profile is always kept
  - (available) **Rename** (always last): a pattern such as `{date:yyyy-MM-dd}_{camera}_{counter:000}`,
    with a live example
- **Presets**: save a pipeline under a name (Save, Save as, rename, delete, reset to the saved version), start from three built-ins, or set up a one-off run without saving. A preset holds the steps, output format and quality, metadata and rename; the output mode stays a global setting.
- **Live preview** of the selected image before and after the pipeline, with its new name and
  size, and a filmstrip of the batch (click a thumbnail or use ← →). Renders happen in the background 300 ms after an edit. The preview (⌥⌘P) and the pipeline can both be collapsed for a compact window; the choice is remembered.
- **Safe runs**: progress with cancel, unreadable files skipped and listed at the end, no
  half-written files, and name collisions resolved with `_2`, `_3`, …

## Screenshots

<!-- Once the UI exists, show the screenshots in a grid with a caption under each (claude-shots
     --write imageconverter refreshes the images), e.g.:
<table>
  <tr>
    <td><img src="docs/main.png" alt="Main window" width="400"><br>The main window with preview</td>
    <td><img src="docs/compact.png" alt="Compact window" width="400"><br>Compact mode during a run</td>
  </tr>
</table>
-->

## Installation

Requires macOS 14 (Sonoma) or later.

- **Download** (from 1.0): a signed and notarized `imageconverter.app`. Move it to Applications
  and open it.
- **From source:**

  ```sh
  swift run           # opens the app window (or: claude-update)
  swift build
  ```

## Configuration

Settings (⌘,). The three output settings below work now. The pipeline itself (steps and output format) is edited in the sidebar and saved automatically (UserDefaults key `currentPipeline`); if it cannot be read at launch you start with an empty pipeline and the default output.

| Setting | Options | Default |
|---------|---------|---------|
| Output mode | New folder · Same folder, new name · Overwrite originals | New folder |
| Output folder | Any folder (used by "New folder") | asked on first run |
| Same-folder suffix | Name suffix used when no Rename step is on | `_converted` |

Metadata and Rename (pipeline steps, saved with the pipeline; "Always last"):

| Option | What it does | Default |
|--------|--------------|---------|
| Metadata | Switches the Metadata step on | off |
| Remove all metadata | Strips all metadata (the color profile is kept) | off |
| Remove location (GPS) | Removes the GPS block and the IPTC city, sub-location, region/state, country and location fields | on |
| Remove camera details | Removes make, model, software, host computer, lens, serial numbers, owner name, maker notes, image unique ID, Exif aux and RAW/DNG/CIFF camera data | off |
| Set artist / copyright / description | Writes the text after the removal (an empty text removes the field) | off |
| Rename | Switches the Rename step on | off |
| Pattern | Rename pattern, see the token table below | `{name}` |
| Counter starts at | First `{counter}` value, 0 to 999 999 999 | 1 |

Watermark (pipeline step, saved with the pipeline):

| Option | What it does | Default |
|--------|--------------|---------|
| Content | Text or Image | Text (a new step starts with `© ` and your full name) |
| Text | The text to draw | `©` |
| Font | Helvetica Bold, Helvetica, Avenir Next Demi Bold, Georgia Bold, Menlo Bold or System bold | Helvetica-Bold |
| Color | Text colour (with transparency) | white |
| Image | A logo or picture to draw | none |
| Position | One of nine anchor points | bottom right |
| Size | Percent of the shorter side of the photo (1 to 100 %) | 4 % for text, 20 % for an image |
| Opacity | 0 to 100 % | 65 % |
| Margin | Distance from the edges, percent of the shorter side (0 to 25 %) | 3 % |

Presets and preview:

| Setting | What it is | Default |
|---------|------------|---------|
| Presets folder | `~/Library/Application Support/imageconverter/presets/`, one `<UUID>.json` file per preset | created on first save |
| Web export (built-in) | Resize fit 2048 × 2048, color sRGB, metadata strip location, JPEG 82 % | n/a |
| Instagram 4:5 (built-in) | Resize exact 1080 × 1350 fill & crop, sRGB, metadata strip location, JPEG 85 % | n/a |
| Archive TIFF (built-in) | No image steps, metadata off, TIFF LZW | n/a |
| Show preview | View → Hide Preview / Show Preview (⌥⌘P); UserDefaults key `previewCollapsed` | shown |
| Pipeline collapsed | The Collapse/Expand button in the sidebar; key `pipelineCollapsed` | expanded |

In *Overwrite originals* mode, a rename that only changes letter case keeps the original name.

CMYK and indexed-colour sources are converted to sRGB by pixel steps (colour-managed, so they
look the same). Gray images stay gray (with or without transparency), and wide-colour (Display P3)
images keep their colour space.

Choosing **Overwrite originals** shows a warning once, when you select it, and never during runs.
In this mode, when the format or name changes (for example HEIC → JPEG), the new file is written
and the original is **moved to the Trash**. In "New folder" mode, dropped folders keep their
subfolder structure.

Planned for the signed 1.0 release: the app will be sandboxed, so it can only touch files and
folders you drop or pick. When you drop loose files and write next to them, it will ask once per
folder for access and remember your answer. Until then it runs unsandboxed.

## How to

### Save a preset

1. Build the pipeline, then press **⌘S** (or Save in the preset bar). On a built-in or a one-off
   pipeline this opens "Save as": type a name (1 to 80 characters, unique) and confirm.
2. Pick a preset in the preset bar to load it. If you have unsaved changes, you are asked
   "Discard changes to <name>?" first. Reset returns to the saved version; rename and delete are in
   the preset bar. Built-ins can't be changed or deleted.

### Preview before running

1. Add images; the preview pane on the right shows the first one before and after the pipeline,
   with `old name → new name` and `W × H → W × H` underneath.
2. Click a thumbnail in the filmstrip, or focus it and press ← / →, to look at another image.
3. Edit a step: the preview updates 300 ms later, and shows a spinner meanwhile. If an image can't
   be rendered, the reason is shown instead of the "after" image. The preview shows the name for
   that image alone; numbers like `_2` that avoid clashes within a batch appear only when you run it.
4. Hide the preview with the button or ⌥⌘P; the window shrinks to the sidebar.

### Build a pipeline

1. In the sidebar, press **+ Add step** and pick Resize, Crop, Rotate / flip, Canvas / padding or
   Color profile. The step is added at the end and opens so you can set it.
2. Open or close a step by clicking its row; its settings (size, anchor, colour, profile, ...) are
   inside. The muted line under the name summarises them. The header shows how many steps are on.
3. Reorder by dragging the handle, or with the keyboard: the **⋯** menu (also the right-click
   menu) has **Move Up**, **Move Down** and **Remove**.
4. Switch a step off with its toggle to skip it without losing its settings; it is dimmed.
5. Steps run top to bottom on every image. The **Output** row is always last: format, quality and
   where files go. **Collapse** in the header hides the whole list.

Your pipeline is kept between launches.

### Convert a batch

1. Drop images or folders onto the window, or press **Add…** (⌘O). Folders are searched
   recursively. File types macOS can't read (for example SVG or PDF) are ignored when you add
   them; broken files of a readable type are skipped during the run and listed at the end.
2. Under **Output** (the last row of the pipeline), pick a format (JPEG, PNG, HEIC, TIFF, plus GIF, BMP and JPEG 2000 where your
   Mac can write them). JPEG, HEIC and JPEG 2000 have a quality slider; TIFF has a compression
   choice.
3. Check the one-line output summary. **Change…** opens Settings (⌘,) to switch between *New
   folder*, *Same folder, new name* and *Overwrite originals*.
4. Press **Run on N images** (⌘R). In *New folder* mode with no folder chosen yet, you are asked to
   pick one first. Cancel with ⌘. at any time; files already finished stay, and no half-written
   files are left.
5. When it ends, a notice shows the result. Files that could not be converted are listed in the
   sidebar (name and reason) until the next run.

### Strip location before sharing

1. In the pipeline, under **Always last**, open **Metadata** and switch it on.
2. Leave **Remove location (GPS)** on. Add **Remove camera details** to drop the make, model, lens
   and serial numbers too, or **Remove all metadata** to strip everything.
3. Optionally tick **Set artist**, **Set copyright** or **Set description** and type the text; it is
   written after the removal, so it survives. Untick to leave a field as it is. A ticked field with empty text removes that field.
4. Run the batch. The removed information is not in the output files. The color profile is always
   kept, so the images look the same.

### Rename by date and camera

1. Open **Rename** (under **Always last**) and switch it on.
2. Type a pattern, for example `{date:yyyy-MM-dd}_{camera}_{counter:000}`, or build it with
   **Insert token**, which appends at the end.
3. The line under the pattern shows an example from the first image in the batch (or a sample
   photo when the batch is empty), such as `Example: 2026-11-13_iPhone 15 Pro_001.jpg`. An
   unknown token like `{foo}` is flagged with a warning and kept as written (`:` still becomes `-`).
4. Set **Counter starts at** if numbering should not begin at 1. The counter follows input order.
5. In *Same folder* mode the pattern replaces the suffix (the summary says "Same folder,
   renamed"). Names that come out identical get `_2`, `_3`, …

Rename tokens:

| Token | Meaning | Example |
|-------|---------|---------|
| `{name}` | Original file name without extension | `IMG_0001` |
| `{ext}` | Output file extension | `jpg` |
| `{date}` / `{date:<format>}` | Capture date (EXIF, else file creation date); default `yyyy-MM-dd` | `2026-11-13`, `{date:yyyyMMdd}` gives `20261113` |
| `{time}` / `{time:<format>}` | Capture time; default `HHmmss` | `140509`, `{time:HH-mm}` gives `14-05` |
| `{camera}` | Camera model | `iPhone 15 Pro` |
| `{make}` | Camera maker | `Apple` |
| `{lens}` | Lens model | `iPhone 15 Pro back camera 6.765mm f/1.78` |
| `{iso}` | ISO speed | `80` |
| `{width}` / `{height}` | Pixel size of the output, after the image steps | `1600` / `1200` |
| `{format}` | Output format | `JPEG` |
| `{folder}` | Name of the source folder | `Holiday` |
| `{counter}` / `{counter:000}` | Running number; the zeros set the padding | `1`, `{counter:000}` gives `001` |

Metadata is untrusted, so names are sanitised: `/` and `:` become `-`; control, bidi and invisible
(zero-width) characters are removed; an empty token drops one neighbouring separator (`_`, `-` or
space); leading dots and separators at the ends are trimmed; names are capped at 200 characters
and 240 bytes; and an empty result falls back to the original name (or `image`).

### Add a watermark

1. Press **+ Add step** and pick **Watermark**. A new step is text and starts with `© ` and your full name.
2. Choose **Text** (edit the text, font and colour) or **Image** (**Choose image…**, for example a
   logo with a transparent background; **Remove** clears it). Switching back and forth keeps what you entered.
3. Pick a **Position** in the 3 x 3 grid.
4. Set **Size**: it is a percentage of the photo's *shorter* side, so the mark looks the same on
   landscape and portrait photos. For an image it is the watermark's width; for text it is the height of a line of text.
   Defaults are 4 % for text and 20 % for an image (switching content switches the size too, unless you changed it).
5. Set **Opacity** and **Margin** (distance from the edges, also a percentage of the shorter side).
   The mark is always scaled down to fit inside the photo with twice the margin removed, so it is never cut off.
6. Put the step after resizing and cropping if the mark should be sized to the final image. If an
   image watermark can't be read when the batch runs, those files are skipped and listed.

(More how-tos once the features exist: build and save a preset.)

## Tests

```sh
swift test
swiftlint           # if installed (brew install swiftlint)
```

## License

MIT. See [LICENSE](LICENSE).
