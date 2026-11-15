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

imageconverter runs on your Mac on files you give it. It has **no network access except the optional update
check and download from github.com** (no telemetry, no uploads). Its only network entitlement is outgoing
connections (`network.client`, no server); the networking code is confined to
`Sources/Imageconverter/Update/UpdateClient.swift`, and a test fails the build if networking APIs or web addresses
appear anywhere else in the sources. That entitlement applies to the whole process, so the sandbox no longer stops
the parsers (ImageIO, the SVG sanitiser and rasteriser) from reaching the network: the sanitiser's refusal of
anything external and that test are now the barriers. The assets an attacker could want are your files and your private metadata (location, serial
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
- **The command line** (`imageconverter`, the `ImageconverterCLIKit` target). Pipeline JSON from `--pipeline`
  is decoded with the same lenient, validated decoder as presets (size-limited, invalid values fall back to
  defaults); argv paths are checked for existence and read like dropped files (same decode limits); options
  are parsed strictly (unknown options are errors). `--json` output is produced by the encoder, never by
  string concatenation, so file names and reasons are escaped.
- **Files are never lost.** Output goes to a temporary file next to its destination and is moved into
  place atomically; unrelated existing files are never replaced.

The App Sandbox is on (user-selected files only). A failing file is skipped and reported; a run never
stops for one bad file.

**Temporary files** (`.imageconverter-<UUID>.tmp`) are removed when a run is cancelled, when the app
quits and at the start of a run. They are deleted, not securely wiped: on SSDs and APFS, overwriting does
not reliably overwrite old blocks, so the app does not claim to.

**Updates** (opt-in: asked once at the first launch; Check Now in About works on demand). The GitHub API
answer and every download are untrusted:

- **The release check** goes only to `api.github.com` over HTTPS, in an ephemeral session (no cookies, cache or
  stored credentials). GitHub sees the IP address and the standard headers macOS adds (e.g. `Accept-Language`,
  `Accept-Encoding`); the app adds only `User-Agent: imageconverter/<version>`. The answer is capped at 1 MB while
  it streams and parsed strictly: tag `v` + `x.y.z` and newer than the running app (no downgrade or
  reinstall), no draft or prerelease, assets named exactly `imageconverter-<x.y.z>.zip` and `.zip.sha256`,
  asset URLs `https` on `github.com`, `objects.githubusercontent.com` or `release-assets.githubusercontent.com`.
  Release notes are shown as plain text, never rendered as Markdown or HTML.
- **Downloads** must stay on those hosts on every redirect and in the final response; the checksum file is
  capped at 1 KB and the zip at 200 MB, counted while it arrives (a declared length is not trusted alone).
- **The zip** must match its SHA-256; its listing is checked before unpacking: at most 20,000 entries, 1 GB
  unpacked in total and 8 MB of `zipinfo` listing, names only inside one `imageconverter.app`, no absolute
  paths, `..` or writes through links (compared ignoring case and Unicode normalisation, as APFS does). It is unpacked with `ditto` into a
  fresh folder in the app's temporary directory, and must hold exactly one `imageconverter.app` with no link
  resolving outside it and the release's version. The SHA-256 comes from the same release, so it guards
  against corruption, not a compromised release: that is the signature's job.
- **The signature** is checked with `SecStaticCodeCheckValidityWithErrors` (all architectures, strict, nested
  code, revocation checks enforced, so the system may ask Apple about the certificate; so may the `notarized`
  requirement when a ticket isn't stapled, which `release.sh` always does) against `anchor apple generic and identifier "io.github.jozeta.imageconverter" and
  certificate leaf[subject.OU] = "6W6TD6P8G3" and notarized`. Anything that fails is refused, its folder
  deleted and the installed app left untouched.
- **Installing** is checked before downloading: refused outside the packaged app, while a batch or job runs
  (checked again right before the swap), and from a translocated or read-only location. The sandboxed app needs
  the folder holding it, asked for once with an open panel and kept as a folder grant (lasting write access to
  that folder, e.g. Applications, until removed in Help ▸ Folder Access…). The swap stays inside that folder: the
  verified app is copied in as a hidden `.imageconverter-update-<uuid>.app` and its links, version and signature
  are checked again there (so nothing can change it between the check and the move, even while the access panel
  waits); the old app is renamed to `.imageconverter-old-<uuid>.app`, the copy renamed into place (the old one
  renamed back on failure), and only then is the old one trashed (or deleted). No step needs the Trash to undo.

Known limits: the zip is unpacked before its signature can be checked; the caps above bound what a compromised
release can make the app write (`ditto` uses its own parser, so the caps are on what `zipinfo` reports). If the
app is killed mid-swap, a hidden sibling can be left next to it.

**Privacy scan.** The app reads headers and metadata only and reports fields by name, never by value.
Help ▸ Privacy… lists the limits in force.
