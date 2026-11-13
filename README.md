# imageconverter

A native macOS app for **batch image processing**. Drop in a pile of images or folders, build a
pipeline once (resize, crop, watermark, clean metadata, rename, convert) and run it over all of
them. It reads every image format your Mac can decode and writes the common ones. Everything happens
on your Mac: no uploads, no network access at all.

For anyone who regularly prepares photos for the web, for sharing or for archiving, and is tired
of doing it one image or one operation at a time.

**Version:** 0.1.0 · **Status:** early development (design agreed, features not built yet).
Started 2026-11-13. The full design is in
[docs/superpowers/specs/2026-11-13-imageconverter-design.md](docs/superpowers/specs/2026-11-13-imageconverter-design.md).

## What's new

### 0.1.0

- Project created. Older versions are listed in [CHANGELOG.md](CHANGELOG.md).

## Features (planned for 1.0)

- **Reads** every format macOS can decode: HEIC, JPEG, PNG, TIFF, GIF, BMP, WebP, AVIF, PSD, camera
  RAW, JPEG 2000, ICNS and more. Animated and multi-page files are read using their first frame.
- **Writes** JPEG, PNG, HEIC and TIFF, plus GIF, BMP and JPEG 2000 where macOS supports them, with
  quality and compression options.
- **Pipeline** of steps, applied in order to every image. Steps can be switched off and reordered:
  - **Resize**: max width, max height, fit inside a box, exact width and/or height (stretch, pad
    or crop to fill), with "don't enlarge" on by default
  - **Crop**: fixed size or aspect ratio, with an anchor point
  - **Rotate / flip**
  - **Canvas / padding**: with a background colour
  - **Color profile**: convert to sRGB, Display P3 or Gray, or keep the original
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

Settings (⌘,), as planned for 1.0:

| Setting | Options | Default |
|---------|---------|---------|
| Output mode | New folder · Same folder, new name · Overwrite originals | New folder |
| Output folder | Any folder (used by "New folder") | asked on first run |
| Same-folder suffix | Name suffix used when no Rename step is on | `_converted` |

Choosing **Overwrite originals** shows a warning once, when you select it, and never during runs.
In this mode, when the format or name changes (for example HEIC → JPEG), the new file is written
and the original is **moved to the Trash**. In "New folder" mode, dropped folders keep their
subfolder structure.

The app is sandboxed. It can only touch files and folders you drop or pick. When you drop loose
files and write next to them, it asks once per folder for access and remembers your answer.

## How to

(Short how-tos for each main task once the features exist: convert a batch, build and save a
preset, rename by date and camera, strip GPS before sharing, add a watermark.)

## Tests

```sh
swift test
swiftlint           # if installed (brew install swiftlint)
```

## License

MIT. See [LICENSE](LICENSE).
