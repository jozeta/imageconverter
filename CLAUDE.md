# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

this is a native image batch converter app

Project type: Swift / macOS app. Created 2026-11-13. **Keep this file up to date** as the project takes shape:
replace the starter sections below with the real commands, architecture and rules once they exist.

## Commands

```sh
swift run           # opens the app window (or: claude-update)
swift build
```

Tests:

```sh
swift test
swiftlint           # if installed (brew install swiftlint)
```

## Layout

- `Package.swift`: SwiftPM manifest (macOS 14+)
- `Sources/Imageconverter/`: the SwiftUI app; `DesignSystem/LadaGlass.swift` is the copied Låda Glass file
- `Sources/ImageconverterCore/`: logic, kept out of the views so it can be tested
- `Tests/ImageconverterCoreTests/`: tests

## Design

Låda Glass 2.2.0 (`~/Desktop/code/tools/design`, preview: `design/preview.html` there): dark frosted
glass is the main theme, light the alternative, compact density. Use its `lg-` components and
tokens instead of new styles; don't edit the vendored copy (update it when `claude-check` says it's
old). UI must stay responsive (no sideways scrolling at 375 px) and keyboard accessible.

## Working agreements

- This repo follows the app standards in `~/Desktop/code/tools/standards/STANDARDS.md` (rule IDs,
  severities). `claude-check --repo .` checks it; decisions and reasoned waivers go in `.claude-standards`.
- Plan before building: agree on goals, scope and tech choices first, then implement in small,
  tested steps (failing test first).
- Never commit secrets. `.env` files are gitignored; commit only `.env.example` with placeholders.
- Untrusted data (network, files, URLs, storage, user input) is rendered with `textContent` or a
  sanitizer, never `innerHTML`; no `eval`; no third-party requests (self-host libraries in `vendor/`).
- Keep CI (`.github/workflows/ci.yml`) green; record user-visible changes under "Unreleased" in
  `CHANGELOG.md`.
- Version 0.1.0 (in `VERSION`). Show it in the app (an About page, `--version` or a footer, read
  from that file). Bump it on every push that changes the app (patch: fixes, minor: features, major:
  breaking changes), and in the same commit move "Unreleased" under the new version and update the
  README's version and "What's new".
- The README stays detailed: what it is, installation, configuration and settings, how-tos, and
  screenshots in a grid with a caption under each.
- There is no GitHub remote yet. Don't push or create repos unless asked.
