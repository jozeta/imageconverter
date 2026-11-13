# Changelog

All notable changes to imageconverter are listed here, newest first.

## Unreleased

- Pipeline steps: resize, crop, rotate/flip, canvas/padding and color profile; steps can be reordered, switched off and removed; the pipeline is kept between launches. Large images are scheduled by memory use; file types macOS can't read (e.g. SVG) are ignored when adding folders.
- Fixes from the milestone 1 review: correct progress count, large folder drops no longer freeze the window, menu commands (Add Images… ⌘O, Run ⌘R, Cancel Run ⌘.), a missing output folder is asked for again.
- Batch conversion: drop images or folders, choose JPEG/PNG/HEIC/TIFF (and GIF/BMP/JPEG 2000 where available), quality, three output modes, progress and cancel; unreadable files are skipped and listed.
- Design agreed: batch pipeline (resize, crop, rotate/flip, canvas, color profile, watermark,
  metadata, rename, output format), presets, layout with collapsible pipeline and preview. See
  `docs/superpowers/specs/2026-11-13-imageconverter-design.md`. README and CLAUDE.md updated.

## 0.1.0 (2026-11-13)

- Project created.
