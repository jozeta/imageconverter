# Auto Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Check GitHub for a newer release from the About window (Check Now + "Check for updates when the app starts"), and download, verify and install it with a relaunch.

**Architecture:** Pure logic in Core (`UpdateRelease` parsing, version comparison, download rules, install plan); the network client, signature verification (Security framework), unpacking (`/usr/bin/ditto`), replacing and relaunching in the app target. One network entry point, allowlisted in `NoNetworkTests`.

**Tech Stack:** Swift 5.10, SwiftUI/AppKit, Foundation `URLSession`, Security (`SecStaticCode`), macOS 14+. No third-party code (no Sparkle).

**Spec:** this plan; the decisions below were agreed with Johan on 2026-11-15 in chat (marked "(Johan)").

## Global Constraints

- Scope: check + download + install + relaunch (Johan). No Sparkle or other third-party code.
- First launch asks once "Check for updates automatically?" (Yes / No); the answer sets the checkbox; nothing goes online before a yes. Check Now always works (Johan). Settings keys: `updateCheckOnLaunch` (Bool, absent until answered), stored via `AppDefaults`.
- About window: current version, **Check Now**, checkbox **Check for updates when the app starts**, a status line ("Checking…", "You're up to date (1.1.0)", "Version 1.2.0 is available", or the error). Låda Glass components only; keyboard accessible.
- Update sheet: "Version X is available", release notes as plain text (never rendered as HTML/Markdown links), **Install and Relaunch** and **Later**. Launch checks stay silent when up to date or on error; Check Now reports both.
- Source: `https://api.github.com/repos/jozeta/imageconverter/releases/latest` (HTTPS only, `User-Agent: imageconverter/<version>`, no other identifying data). Response ≤ 1 MB, untrusted.
- Accept a release only when `tag_name` is `v` + strict `x.y.z` and greater than `AppInfo.version` (never downgrade or reinstall), not a draft/prerelease, with assets named exactly `imageconverter-<x.y.z>.zip` and `imageconverter-<x.y.z>.zip.sha256`.
- Download URLs must be `https` on host `github.com` or `objects.githubusercontent.com` (also after redirects); zip ≤ 200 MB, sha256 file ≤ 1 KB; the SHA-256 must match.
- Unpack into a fresh folder in the app's temporary directory with `/usr/bin/ditto -x -k`; exactly one top-level `imageconverter.app`, no symlink pointing outside the bundle.
- Verify with `SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidityWithErrors` (flags `kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode`) against the requirement `anchor apple generic and identifier "io.github.jozeta.imageconverter" and certificate leaf[subject.OU] = "6W6TD6P8G3" and notarized`; the new bundle's `CFBundleShortVersionString` must equal the release version.
- Install: only from a bundle (`Bundle.main.bundleURL.pathExtension == "app"`), refused while a batch or job runs ("Finish the running batch or job first"). Needs write access to the folder holding the app: in the sandbox ask once with the pre-filled open panel (AccessStore) and keep the bookmark. Move the old app to the Trash, move the new one into place (same name), relaunch with `NSWorkspace.openApplication` (new instance) then terminate. Any failure before the move leaves the old app untouched; a failure after trashing restores it from the Trash location returned by `trashItem`.
- DEBUG / `swift run` (not a bundle): Check Now works and reports; install says "Updates install only in the released app".
- Entitlements: add `com.apple.security.network.client` only. `scripts/release.sh`'s entitlement check and comments change from "no network" to "network client only, no server".
- `NoNetworkTests`: networking APIs and the two GitHub hosts allowed only in the update client file(s) in the app target (`Sources/Imageconverter/Update/`); everywhere else still fails. The CLI gets no update code.
- Docs: README (Privacy wording: "No network access except the optional update check and download from github.com"; About/updates how-to; settings), Help ▸ Privacy statement (`PrivacyStatement`), SECURITY.md, CHANGELOG Unreleased, CLAUDE.md layout. English.

## Review Focus

1. A malicious or broken API response (huge body, bad JSON, `v1.2`, `v01.2.0`, prerelease, wrong asset names, http or foreign-host URLs, redirect to another host) → no install, a clear message, no crash.
2. A tampered zip (hash mismatch, two apps, symlink escape, ad hoc or other-team signature, not notarized, version mismatch) → refused, old app untouched, temp folder deleted.
3. Install while a batch/job runs, or the app folder not writable → refused with a message; nothing moved.
4. Failure after the old app was trashed → old app restored to its path.
5. First launch with no answer stored → exactly one prompt; a "No" means no request on later launches; Check Now still works.

---

### Task 1: Core update logic

**Files:** Create `Sources/ImageconverterCore/Update/UpdateRelease.swift` (GitHub JSON → `UpdateRelease { version: AppVersion, notes: String, zipURL: URL, shaURL: URL }`, all rules above), `AppVersion.swift` (strict x.y.z, `Comparable`), `UpdatePolicy.swift` (`allowedHost(_ url: URL) -> Bool`, size caps, `expectedSHA256(from data: Data, fileName:) -> String?` for the `shasum -a 256` format `<64 hex>  <name>`), `UpdateInstallPlan.swift` (pure decision: `canInstall(isBundle:isRunning:) -> Result`, launch-check decision `shouldCheckOnLaunch(answer: Bool?) -> .ask | .check | .skip`). Tests in `Tests/ImageconverterCoreTests/UpdateTests.swift`.
**Interfaces produced:** the types above, `UpdateRelease.parse(_ data: Data, current: AppVersion) throws -> UpdateRelease?` (nil = up to date), `UpdateError` (user-facing `message`).
- [ ] Tests first for every Review Focus 1 input, version ordering (1.10.0 > 1.9.0), sha file parsing (wrong length, uppercase hex accepted, wrong name rejected), launch decision.
- [ ] Implement; `swift test --filter UpdateTests` passes; commit.

### Task 2: App: About UI, first-launch prompt, client, verify, install

**Files:** Create `Sources/Imageconverter/Update/UpdateClient.swift` (URLSession: fetch release, download with host check on every redirect via delegate, size caps, SHA-256 via CryptoKit — CryptoKit is Apple's), `UpdateVerifier.swift` (ditto unpack, symlink check, SecStaticCode, version check), `UpdateInstaller.swift` (access via AccessStore, trash/move/restore, relaunch), `UpdateController.swift` (@Observable state for About and the sheet; launch check). Modify `AboutView.swift`, `ImageconverterApp.swift` (first-launch prompt, sheet), `AccessStore` if needed, `Resources/imageconverter.entitlements`, `scripts/release.sh`, `NoNetworkTests.swift`, `PrivacyStatement`, README, SECURITY.md, CHANGELOG, CLAUDE.md. Tests: Core-testable pieces stay in Core; app-side verifier logic that can be tested on files (unpack + symlink check + version check with a locally built ad hoc bundle that must be REFUSED by the requirement) goes in Core if needed for testability.
- [ ] Tests first for Review Focus 2–4 where testable without network (local fixtures; installer replace/restore on temp folders with an injected trash).
- [ ] Implement; fresh build 0 warnings; `swift test` 0 failures; `swiftlint --strict` 0; `scripts/release.sh` (ad hoc) passes its entitlement check; commit.
- [ ] Run the DEBUG app with its own defaults suite and screenshot the About window if the screen is available.
