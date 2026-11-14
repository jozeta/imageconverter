# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

If this project is hosted on GitHub, report it privately through the repository's **Security** tab
→ **Report a vulnerability**. Include what you found, how to reproduce it, and the impact you expect.

This is a personal project maintained in spare time. You can expect an acknowledgement within a
week, and fixes as soon as practical.

## Supported versions

Only the latest version on the `main` branch receives security fixes.

## Threat model

imageconverter runs on your Mac, offline, on files you give it. It has **no network access** (no network
entitlement, no telemetry, no updater, no uploads), and a test fails the build if networking APIs appear in
the sources. The assets an attacker could want are your files and your private metadata (location, serial
numbers, names), and the app's stability.

Everything that comes from outside the app is untrusted:

- **Images and their metadata.** Checked from the file size and header before any pixels are decoded
  (`DecodeLimits`): at most 250 megapixels, 65,535 px on a side, min(4 GB, a quarter of the Mac's memory)
  of decoded memory, 2 GB per file, first frame only; likely decompression bombs are refused. Metadata is
  sanitised before it is used in file names and never rendered as markup.
- **SVG watermarks.** At most 1 MB, parsed by a strict allowlist (elements, attributes, simple style rules),
  capped in elements, depth and expanded instances, with reference-graph checks; only the re-serialised
  result is drawn, and nothing is ever fetched.
- **Preset, template and job files** (and imported ones): at most 1 MB, opened without following links,
  validated on load; invalid files are skipped and reported.
- **`imageconverter://` links, Finder services and AppleScript.** Unknown hosts and parameters, duplicates,
  overlong values and unreadable paths are rejected; every action but `open` waits for an in-app
  confirmation naming the files, preset and output, and overwrite mode is always confirmed. Names from
  links are never echoed.
- **Files are never lost.** Output goes to a temporary file next to its destination and is moved into
  place atomically; unrelated existing files are never replaced.

The App Sandbox is on (user-selected files only). A failing file is skipped and reported; a run never
stops for one bad file.

**Temporary files** (`.imageconverter-<UUID>.tmp`) are removed when a run is cancelled, when the app
quits and at the start of a run. They are deleted, not securely wiped: on SSDs and APFS, overwriting does
not reliably overwrite old blocks, so the app does not claim to.

**Privacy scan.** The app reads headers and metadata only and reports fields by name, never by value.
Help ▸ Privacy… lists the limits in force.
