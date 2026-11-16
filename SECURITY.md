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
anything external and that test are now the barriers.
The only other network activity: if you choose to download Apple's
enlargement model (ML enlarge, macOS 26 and later), macOS downloads it from Apple. The app only asks VideoToolbox to
start that download (`downloadConfigurationModel`), from one place (`Sources/Imageconverter/MLEnlargeDownload.swift`,
the Resize editor's Download… button, after a consent alert; a test fails if the call appears anywhere else); batch,
job, command-line, service, script and link runs never start it. Generated alt text (macOS 27 and later) uses only
Apple's on-device system language model (`SystemLanguageModel.default`); the server model class is never used (a test
fails if its name appears in the sources), and the app never asks macOS to download the on-device model. The assets an attacker could want are your files and your private metadata (location, serial
numbers, names), and the app's stability.

Everything that comes from outside the app is untrusted:

- **Images and their metadata.** Checked from the file size and header before any pixels are decoded
  (`DecodeLimits`): at most 250 megapixels, 65,535 px on a side, min(4 GB, a quarter of the Mac's memory)
  of decoded memory, 2 GB per file, first frame only; likely decompression bombs are refused. Metadata is
  sanitised before it is used in file names and never rendered as markup.
- **Model output.** Generated alt text is untrusted text: control and format characters (bidirectional overrides,
  zero-width characters) are stripped, whitespace collapsed and the length capped at 250 characters before it is
  written to metadata; the preview shows it as plain text.
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
  paths, `..` or writes through links (compared ignoring case and Unicode normalisation, as APFS does). It is
  unpacked with `ditto -x -k --noqtn` into a fresh folder under a watchdog: a zip can declare smaller sizes than
  it inflates to (ditto writes what the stream holds, resource forks from `._` entries included), so every 250 ms
  the watchdog takes the larger of the folder's allocated size (all forks) and the free space the volume lost
  since ditto started, and stops ditto (SIGTERM, SIGKILL after 2 s) once that is more than 1 GB + 64 MB or less
  than 2 GB stays free; both are checked again afterwards. What ditto wrote must be what the listing named (ditto
  reads the local headers, `zipinfo` the central directory): nothing outside the one `imageconverter.app`, no
  file or link the listing doesn't name. It must hold exactly one `imageconverter.app` with no link
  resolving outside it and the release's version. The SHA-256 comes from the same release, so it guards
  against corruption, not a compromised release: that is the signature's job.
- **The signature** is checked with `SecStaticCodeCheckValidityWithErrors` (all architectures, strict, nested
  code, revocation checks enforced, so the system may ask Apple about the certificate; so may the `notarized`
  requirement when a ticket isn't stapled, which `release.sh` always does) against `anchor apple generic and identifier "io.github.jozeta.imageconverter" and
  certificate leaf[subject.OU] = "6W6TD6P8G3" and notarized`. Anything that fails is refused, its folder
  deleted and the installed app left untouched.
- **The installer service.** Files a sandboxed process creates are quarantined so that they can't be opened, so
  the sandboxed app only checks and downloads (and checks the SHA-256 for quick feedback). Unpacking, checking
  and installing happen in `Contents/XPCServices/io.github.jozeta.imageconverter.installer.xpc`, an XPC service
  signed with the same identity, hardened runtime, **without the App Sandbox** and without entitlements. It:
  - accepts connections only from a client meeting `anchor apple generic and identifier
    "io.github.jozeta.imageconverter" and certificate leaf[subject.OU] = "6W6TD6P8G3"`
    (`NSXPCConnection.setCodeSigningRequirement`). There is no runtime override; only a build made with
    `SWIFT_FLAGS="-Xswiftc -DUPDATE_E2E"` (for the end-to-end test) accepts the ad hoc test identifier
    `io.github.jozeta.imageconverter.updatetest` instead. `release.sh` refuses that flag with a real identity or
    `--notarize`, and refuses any non-ad-hoc build whose service binary names `.updatetest` (a cached test build);
  - has a two-call interface (`install(zipPath:expectedSHA256:version:)`, `cleanUp`) and trusts none of it: the
    app to replace is derived from the service's own location (`…/X.app/Contents/XPCServices/….xpc`), refused if
    translocated or on a read-only volume; the zip must be a regular file (opened with `O_NOFOLLOW_ANY`: no link anywhere in its path) at exactly
    `~/Library/Containers/<app id>/Data/tmp/imageconverter-update-<UUID>/imageconverter-<version>.zip`, at most
    200 MB, and is copied into the service's own temporary folder before anything else;
  - refuses a version at or below the installed app's own `CFBundleShortVersionString` (no downgrade or
    reinstall, whatever the app asks), then redoes the package checks above on its copy (SHA-256, listing caps,
    watched unpack, unpacked tree against the listing, layout, links, version, signature), removes leftovers of an interrupted install, then swaps inside the app's folder: the verified app
    is copied in as a hidden `.imageconverter-update-<uuid>.app` and checked again there, the old app renamed to
    `.imageconverter-old-<uuid>.app`, the copy renamed into place (the old one renamed back on failure), and only
    then is the old one trashed (or deleted). No step needs the Trash to undo;
  - removes `com.apple.quarantine` from the new app (it passed the notarized requirement) and fails if any stays.
- **Installing** is checked by the app before downloading: refused outside the packaged app or without the
  service, while a batch or job runs (checked again right before calling the service), and from a translocated
  or read-only location. No folder access is asked for or kept: the service writes the app's folder with the
  user's own permissions, and refuses when the user can't.

Known limits: the zip is unpacked before its signature can be checked. The watchdog bounds what a compromised
release can make the installer write by the space actually used (about 1 GB plus what slips in between two 250 ms
checks, and never below 2 GB free); other processes writing at the same time count against it too. The service
runs with the user's full permissions. The client requirement keeps other programs out, but a compromised
imageconverter process (for example through a crafted image) still meets it and chooses both the zip and its
SHA-256: then only the service's own checks protect, above all the Developer ID + notarized requirement and the
newer-version rule, so at worst a genuine newer release is installed. A quarantine mark that can't be removed after
a good swap is logged, not reported as a failure. A batch or job started between the app's last check and the swap
keeps running from the old code.

**Privacy scan.** The app reads headers and metadata only and reports fields by name, never by value.
Help ▸ Privacy… lists the limits in force.
