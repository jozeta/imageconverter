# imageconverter

A native macOS app for **batch image processing**. Drop in a pile of images or folders, build a
pipeline once (resize, crop, watermark, clean metadata, rename, convert) and run it over all of
them. It reads every image format your Mac can decode and writes the common ones. Everything happens
on your Mac: no uploads, no network access at all.

For anyone who regularly prepares photos for the web, for sharing or for archiving, and is tired
of doing it one image or one operation at a time.

**Version:** 0.1.0 · **Status:** early development (milestone 1, batch conversion, works; the image steps resize, crop, rotate/flip, canvas and color profile are available; watermark, metadata, rename and presets are coming).
Started 2026-11-13. The full design is in
[docs/superpowers/specs/2026-11-13-imageconverter-design.md](docs/superpowers/specs/2026-11-13-imageconverter-design.md).

## What's new

### Unreleased

- Wide-colour (Display P3) photos keep their colour when resized and saved as JPEG; opaque images stay opaque through steps; memory use accounts for enlargement.
- Pipeline steps: resize, crop, rotate/flip, canvas/padding and color profile; steps can be reordered, switched off and removed; the pipeline is kept between launches. Large images are scheduled by memory use; file types macOS can't read (e.g. SVG) are ignored when adding folders.

### 0.1.0

- Project created. Older versions are listed in [CHANGELOG.md](CHANGELOG.md).

## Features (image steps available now; the rest planned for 1.0)

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
  - **Watermark**: text or image, with position, size and opacity controls
  - **Metadata** (always last): strip everything, GPS only or camera details, or set artist,
    copyright and description
  - **Rename** (always last): a pattern such as `{date:yyyy-MM-dd}_{camera}_{counter:000}`
- **Presets**: save a pipeline under a name, or set up a one-off run without saving.
- **Live preview** of the selected image before and after the pipeline, with its new name and
  size. The preview and the pipeline can both be collapsed for a compact window.
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

Gray, CMYK and indexed-colour sources are converted to sRGB by pixel steps (colour-managed, so
they look the same). Wide-colour (Display P3) images keep their colour space.

Choosing **Overwrite originals** shows a warning once, when you select it, and never during runs.
In this mode, when the format or name changes (for example HEIC → JPEG), the new file is written
and the original is **moved to the Trash**. In "New folder" mode, dropped folders keep their
subfolder structure.

Planned for the signed 1.0 release: the app will be sandboxed, so it can only touch files and
folders you drop or pick. When you drop loose files and write next to them, it will ask once per
folder for access and remember your answer. Until then it runs unsandboxed.

## How to

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

(More how-tos once the features exist: build and save a preset, rename by date and camera, strip
GPS before sharing, add a watermark.)

## Tests

```sh
swift test
swiftlint           # if installed (brew install swiftlint)
```

## License

MIT. See [LICENSE](LICENSE).
