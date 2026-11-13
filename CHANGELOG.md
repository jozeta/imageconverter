# Changelog

All notable changes to imageconverter are listed here, newest first.

## Unreleased

- Window: grab handles on the panel edges replace the "Show/Hide preview" and "Collapse" buttons (also View > Hide Preview ⌥⌘P and Collapse Pipeline ⌥⌘L); the window resizes smoothly when the preview or the pipeline is toggled. With the preview hidden the window is exactly the sidebar's size; with it open the window can be resized (at least 780 × 560 pt) and the sidebar panel stretches to its height, so there is no empty space around the panels. Full screen is off for the main window.
- Pipeline rows: drag handle with an insertion line replaces the actions menu (Move Up/Down stay in the context menu and as accessibility actions), a small remove button, "+ Add step" above the steps (new steps start collapsed), switched-off steps collapse and cannot be expanded, and tighter spacing.
- Output row: a "Save to" dropdown replaces the Settings window (⌘, is gone), an "Original → about" size estimate, a Rename step that is greyed out while overwriting, and find and replace (plain or regular expression) in the Rename step. The same-folder suffix now defaults to `_new`.
- Preview and preset fixes: a failed preview no longer shows the previous image, the preview toggle (⌥⌘P) resizes the main window, ⌘S is disabled while running, preset names ignore look-alike spaces, skipped preset files give specific reasons, and images whose originals were trashed are removed with a notice.
- Preview: the one-line info is now an Original | Result table (name, folder, dimensions, size with a live estimate); during a run the progress bar and Cancel sit above it (the sidebar keeps them when the preview is hidden).
- Presets (save, save as, rename, delete, reset; three built-ins) and a collapsible before/after preview with a filmstrip of the batch.
- Watermark fixes: an unreadable watermark image now fails the batch immediately without decoding the photos, large logos are downsampled on load (4096 px), tall glyphs and emoji stay inside the watermark's box, line breaks in the text become spaces, image watermarks default to 20 % size when loading older settings, and an empty text shows a hint.
- Watermark step: text (font, colour) or image (e.g. a logo), with position, size relative to the image, opacity and margin.
- Metadata step (remove location, camera details or everything; set artist, copyright and description) and Rename step with tokens ({date}, {camera}, {counter:000}, …) and a live example.
- Wide-colour (Display P3) photos keep their colour when resized and saved as JPEG.
- Pipeline steps: resize, crop, rotate/flip, canvas/padding and color profile; steps can be reordered, switched off and removed; the pipeline is kept between launches. Large images are scheduled by memory use; file types macOS can't read (e.g. SVG) are ignored when adding folders.
- Fixes from the milestone 1 review: correct progress count, large folder drops no longer freeze the window, menu commands (Add Images… ⌘O, Run ⌘R, Cancel Run ⌘.), a missing output folder is asked for again.
- Batch conversion: drop images or folders, choose JPEG/PNG/HEIC/TIFF (and GIF/BMP/JPEG 2000 where available), quality, three output modes, progress and cancel; unreadable files are skipped and listed.
- Design agreed: batch pipeline (resize, crop, rotate/flip, canvas, color profile, watermark,
  metadata, rename, output format), presets, layout with collapsible pipeline and preview. See
  `docs/superpowers/specs/2026-11-13-imageconverter-design.md`. README and CLAUDE.md updated.

## 0.1.0 (2026-11-13)

- Project created.
