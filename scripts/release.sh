#!/usr/bin/env bash
# Builds dist/imageconverter.app (universal, sandboxed, hardened runtime) with the command-line tool inside at
# Contents/Helpers/imageconverter and the update installer service (not sandboxed) at
# Contents/XPCServices/io.github.jozeta.imageconverter.installer.xpc and the App Intents metadata Shortcuts reads
# (Contents/Resources/Metadata.appintents, made by Xcode's appintentsmetadataprocessor from the SwiftPM build's
# compiler output; needs Xcode, not only the Command Line Tools), signs it and zips it.
#
# Usage: scripts/release.sh [--notarize]
#
# Environment:
#   SIGN_IDENTITY   codesign identity (default "-": ad hoc, for local testing; nothing is notarized)
#   NOTARY_PROFILE  notarytool keychain profile (`xcrun notarytool store-credentials`); needed for --notarize
#   SKIP_APPINTENTS set to 1 to build without Contents/Resources/Metadata.appintents (no Shortcuts actions). Only for
#                   CI, whose older Xcode can't run this script's metadata step; refused with a real identity or
#                   --notarize, so a release always has the Shortcuts actions.
#   SWIFT_FLAGS     extra `swift build` arguments, split on spaces (e.g. "-Xswiftc -DUPDATE_E2E" for the update
#                   end-to-end test build, whose installer service accepts the ad hoc ...updatetest app). UPDATE_E2E is
#                   refused with a real identity or --notarize, and a non-ad-hoc build whose service mentions
#                   ".updatetest" (a cached test build) is refused too.
#
# Results: dist/imageconverter.app and
#   dist/imageconverter-<version>.zip              signed with a Developer ID, notarized and stapled (--notarize)
#   dist/imageconverter-<version>-not-notarized.zip  signed with a real identity, not notarized
#   dist/imageconverter-<version>-unsigned-adhoc.zip ad hoc signature (runs only on this Mac without a warning)
# each with a .sha256 file next to it. Credentials stay in the keychain; none are read or printed here.
set -euo pipefail

BUNDLE_ID="io.github.jozeta.imageconverter"
CLI_ID="$BUNDLE_ID.cli"
INSTALLER_ID="$BUNDLE_ID.installer"
APP_NAME="imageconverter"
EXECUTABLE="Imageconverter"

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

die() { echo "release.sh: $*" >&2; exit 1; }
warn() { echo "release.sh: warning: $*" >&2; }

notarize=false
for argument in "$@"; do
    case "$argument" in
        --notarize) notarize=true ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option '$argument' (usage: scripts/release.sh [--notarize])" ;;
    esac
done

identity="${SIGN_IDENTITY:--}"
# The end-to-end test switch relaxes who may use the installer service; it must never reach a release.
if [[ "${SWIFT_FLAGS:-}" == *UPDATE_E2E* ]] && { [ "$identity" != "-" ] || [ "$notarize" = true ]; }; then
    die "SWIFT_FLAGS has UPDATE_E2E (the update end-to-end test build); it is only allowed for ad hoc builds without --notarize."
fi
skip_appintents=false
case "${SKIP_APPINTENTS:-}" in
    "" | 0) ;;
    1) skip_appintents=true ;;
    *) die "SKIP_APPINTENTS must be 1 (or unset), not '${SKIP_APPINTENTS}'." ;;
esac
# A release without Metadata.appintents has no Shortcuts actions; the skip is only for ad hoc CI builds.
if [ "$skip_appintents" = true ] && { [ "$identity" != "-" ] || [ "$notarize" = true ]; }; then
    die "SKIP_APPINTENTS=1 builds an app without Shortcuts actions; it is only allowed for ad hoc builds without --notarize."
fi
if [ "$skip_appintents" = false ]; then
    # Checked before building: without Xcode the metadata step can't run.
    processor=$(xcrun --find appintentsmetadataprocessor 2>/dev/null) \
        || die "appintentsmetadataprocessor not found: the Shortcuts actions need Xcode (xcode-select -s /Applications/Xcode.app), not only the Command Line Tools."
fi
if [ "$notarize" = true ]; then
    [ "$identity" != "-" ] || die "--notarize needs a Developer ID identity in SIGN_IDENTITY (ad hoc signatures can't be notarized)."
    [ -n "${NOTARY_PROFILE:-}" ] || die "--notarize needs NOTARY_PROFILE (a keychain profile made with 'xcrun notarytool store-credentials')."
    xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not found (install Xcode or its command line tools)."
fi

# --- Version and identifiers --------------------------------------------------------------------------------
version=$(tr -d '[:space:]' < VERSION)
# Strictly x.y.z: CFBundleShortVersionString must be numeric (no pre-release suffix).
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "VERSION '$version' is not x.y.z (three numbers, no suffix)."
build=$(git rev-list --count HEAD 2>/dev/null) || die "can't count commits for CFBundleVersion (not a git checkout?)."
# Copyright from the last commit's year and LICENSE's holder, so the same commit always gives the same Info.plist.
year=$(git log -1 --format=%cd --date=format:%Y)
holder=$(sed -n 's/^Copyright (c) [0-9, -]* //p' LICENSE | head -n 1)
[ -n "$holder" ] || die "no 'Copyright (c) <year> <name>' line in LICENSE."

# The command-line tool finds the app's container by this identifier; both must agree.
grep -q "bundleIdentifier = \"$BUNDLE_ID\"" Sources/ImageconverterCLIKit/CLIDataDirectory.swift \
    || die "BUNDLE_ID ($BUNDLE_ID) differs from CLIDataDirectory.bundleIdentifier."
# The app connects to the installer service by this name.
grep -q "name = \"$INSTALLER_ID\"" Sources/ImageconverterCore/Update/UpdateInstallerProtocol.swift \
    || die "INSTALLER_ID ($INSTALLER_ID) differs from UpdateInstallerService.name."
# Updates accept only a downloaded app with this identifier (UpdatePolicy.codeRequirement).
grep -q "bundleIdentifier = \"$BUNDLE_ID\"" Sources/ImageconverterCore/Update/UpdatePolicy.swift \
    || die "BUNDLE_ID ($BUNDLE_ID) differs from UpdatePolicy.bundleIdentifier."

echo "==> imageconverter $version (build $build), identity: $([ "$identity" = "-" ] && echo "ad hoc" || echo "$identity")"

# --- Build ----------------------------------------------------------------------------------------------------
dist="$root/dist"
mkdir -p "$dist"
# Everything is assembled in here and moved into dist/ only once it is signed and verified, so a failed run never
# leaves a finished-looking app behind. Inside dist/ so the final move stays on one volume.
work=$(mktemp -d "$dist/.release-XXXXXX")
trap 'rm -rf "$work"' EXIT

extra=()
if [ -n "${SWIFT_FLAGS:-}" ]; then
    read -r -a extra <<< "$SWIFT_FLAGS"
    warn "building with SWIFT_FLAGS: ${extra[*]}"
fi
universal=(-c release --arch arm64 --arch x86_64 ${extra[@]+"${extra[@]}"})
build_log="$work/build.log"
if swift build "${universal[@]}" --product "$EXECUTABLE" 2>&1 | tee "$build_log" \
    && swift build "${universal[@]}" --product imageconverter-cli 2>&1 | tee -a "$build_log" \
    && swift build "${universal[@]}" --product imageconverter-installer 2>&1 | tee -a "$build_log"; then
    bin=$(swift build "${universal[@]}" --show-bin-path)
elif grep -Eiq "unable to find utility \"?xcbuild|xcbuild.*not found|requires xcode|multiple (--arch|architectures).*not supported" "$build_log"; then
    # Only a toolchain that can't build a second architecture (Command Line Tools without Xcode) falls back. That
    # is reachable only with SKIP_APPINTENTS=1: otherwise the missing Xcode stopped the script before the build.
    warn "this toolchain can't build a universal binary (needs Xcode); building for $(uname -m) only."
    single=(-c release ${extra[@]+"${extra[@]}"})
    swift build "${single[@]}" --product "$EXECUTABLE"
    swift build "${single[@]}" --product imageconverter-cli
    swift build "${single[@]}" --product imageconverter-installer
    bin=$(swift build "${single[@]}" --show-bin-path)
else
    die "the release build failed (see the errors above)."
fi
[ -x "$bin/$EXECUTABLE" ] && [ -x "$bin/imageconverter-cli" ] && [ -x "$bin/imageconverter-installer" ] \
    || die "built products not found in $bin."
if [ "$identity" != "-" ]; then
    # Also catches a cached UPDATE_E2E build that SWIFT_FLAGS no longer mentions.
    strings "$bin/imageconverter-installer" > "$work/installer-strings.txt"
    grep -q 'imageconverter\.updatetest' "$work/installer-strings.txt" \
        && die "the installer service was built with UPDATE_E2E (it accepts the test app); rebuild without it."
fi

# --- App Intents metadata (Shortcuts) ---------------------------------------------------------------------------
# Shortcuts only lists an app's actions when the bundle has Contents/Resources/Metadata.appintents. Xcode makes it
# in a build phase that SwiftPM doesn't run, so it is made here with Xcode's own tool from what the universal
# (Xcode build system) `swift build` left: the app module's source list and the compiler's constant values
# (.swiftconstvalues, one per architecture). The intents are in Sources/Imageconverter/Intents/.
intents=(ConvertImagesIntent ApplyPresetToFolderIntent RunJobIntent StripMetadataIntent ResizeImagesIntent
         ConvertFormatIntent GetImageMetadataIntent)
make_appintents_metadata() {
    intermediates="$(dirname "$(dirname "$bin")")/Intermediates.noindex"
    module_build=$(find "$intermediates" -type d -path "*/Release/$EXECUTABLE-p.build" 2>/dev/null | head -n 1)
    [ -n "$module_build" ] || die "no build intermediates for $EXECUTABLE in $intermediates (the universal build makes them)."
    metadata_args=()
    for arch in arm64 x86_64; do
        objects="$module_build/Objects-normal/$arch"
        [ -f "$objects/$EXECUTABLE.SwiftFileList" ] || die "no $arch source list in $objects."
        find "$objects" -maxdepth 1 -name '*.swiftconstvalues' > "$work/constvalues-$arch.txt"
        [ -s "$work/constvalues-$arch.txt" ] || die "no $arch .swiftconstvalues in $objects."
        metadata_args+=(--target-triple "$arch-apple-macos14.0" --source-file-list "$objects/$EXECUTABLE.SwiftFileList"
                        --swift-const-vals-list "$work/constvalues-$arch.txt")
    done
    : > "$work/no-dependency-metadata.txt"
    toolchain=$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")
    xcode_build=$(xcodebuild -version 2>/dev/null | sed -n 's/^Build version //p')
    mkdir -p "$work/appintents"
    "$processor" --toolchain-dir "$toolchain" --module-name "$EXECUTABLE" --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "${xcode_build:-unknown}" --platform-family macOS --deployment-target 14.0 \
        --bundle-identifier "$BUNDLE_ID" --output "$work/appintents" --binary-file "$bin/$EXECUTABLE" \
        "${metadata_args[@]}" --metadata-file-list "$work/no-dependency-metadata.txt" \
        --static-metadata-file-list "$work/no-dependency-metadata.txt" --force --compile-time-extraction \
        --deployment-aware-processing --no-app-shortcuts-localization > "$work/appintents.log" 2>&1 \
        || { cat "$work/appintents.log" >&2; die "the App Intents metadata processor failed."; }
    grep -i "warning" "$work/appintents.log" >&2 || true
    actions_data="$work/appintents/Metadata.appintents/extract.actionsdata"
    [ -f "$actions_data" ] || { cat "$work/appintents.log" >&2; die "no Metadata.appintents was made (no intents found)."; }
}
if [ "$skip_appintents" = true ]; then
    echo "==> App Intents metadata skipped (SKIP_APPINTENTS=1)"
else
    make_appintents_metadata
fi

# --- Assemble -------------------------------------------------------------------------------------------------
app="$work/$APP_NAME.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Helpers"
ditto "$bin/$EXECUTABLE" "$contents/MacOS/$EXECUTABLE"
# Named imageconverter in the bundle; the build product can't be (it would clash with Imageconverter on a
# case-insensitive volume).
ditto "$bin/imageconverter-cli" "$contents/Helpers/imageconverter"
scripts/make-iconset.sh Resources/AppIcon.png "$contents/Resources/AppIcon.icns" >/dev/null
cp Resources/imageconverter.sdef "$contents/Resources/imageconverter.sdef"
if [ "$skip_appintents" = false ]; then
    ditto "$work/appintents/Metadata.appintents" "$contents/Resources/Metadata.appintents"
    # Every Shortcuts action must be listed, run without opening the app, and have its App Shortcut phrases.
    bundled_actions="$contents/Resources/Metadata.appintents/extract.actionsdata"
    for intent in "${intents[@]}"; do
        [ "$(plutil -extract "actions.$intent.identifier" raw "$bundled_actions" 2>/dev/null)" = "$intent" ] \
            || die "Metadata.appintents doesn't list the $intent action."
        [ "$(plutil -extract "actions.$intent.openAppWhenRun" raw "$bundled_actions" 2>/dev/null)" = false ] \
            || die "the $intent action would open the app (openAppWhenRun must be false)."
    done
    # `raw` prints a dictionary's keys one per line (and an array's count).
    action_count=$(plutil -extract actions raw "$bundled_actions" 2>/dev/null | grep -c . || true)
    [ "$action_count" = "${#intents[@]}" ] \
        || die "Metadata.appintents lists $action_count actions, expected ${#intents[@]} (update the list in release.sh)."
    [ "$(plutil -extract autoShortcuts raw "$bundled_actions" 2>/dev/null || echo 0)" = "${#intents[@]}" ] \
        || die "Metadata.appintents doesn't have one App Shortcut per action."
fi
printf 'APPL????' > "$contents/PkgInfo"

# The update installer XPC service: unpacks, checks and installs updates outside the sandbox (files the sandboxed
# app creates are quarantined and can't be opened). It accepts only this app (InstallerPolicy.clientRequirement).
xpc="$contents/XPCServices/$INSTALLER_ID.xpc"
mkdir -p "$xpc/Contents/MacOS"
ditto "$bin/imageconverter-installer" "$xpc/Contents/MacOS/imageconverter-installer"
xpc_plist="$xpc/Contents/Info.plist"
plutil -create xml1 "$xpc_plist"
plutil -insert CFBundleIdentifier -string "$INSTALLER_ID" "$xpc_plist"
plutil -insert CFBundleExecutable -string imageconverter-installer "$xpc_plist"
plutil -insert CFBundleName -string imageconverter-installer "$xpc_plist"
plutil -insert CFBundlePackageType -string 'XPC!' "$xpc_plist"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$xpc_plist"
plutil -insert CFBundleShortVersionString -string "$version" "$xpc_plist"
plutil -insert CFBundleVersion -string "$build" "$xpc_plist"
plutil -insert LSMinimumSystemVersion -string 14.0 "$xpc_plist"
plutil -insert XPCService -dictionary "$xpc_plist"
plutil -insert XPCService.ServiceType -string Application "$xpc_plist"
plutil -lint "$xpc_plist" >/dev/null

plist="$contents/Info.plist"
cp scripts/Info.plist.template "$plist"
sed "s/BUNDLE_IDENTIFIER/$BUNDLE_ID/g" Resources/Info-fragments.plist > "$work/fragments.plist"
plutil -lint -s "$work/fragments.plist"
/usr/libexec/PlistBuddy -c "Merge $work/fragments.plist" "$plist" >/dev/null
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$build" "$plist"
plutil -replace NSHumanReadableCopyright -string "Copyright © $year $holder. MIT License." "$plist"
plutil -convert xml1 "$plist"
plutil -lint "$plist" >/dev/null
grep -q BUNDLE_IDENTIFIER "$plist" && die "a BUNDLE_IDENTIFIER placeholder is left in Info.plist."
[ "$(plutil -extract CFBundleName raw "$plist")" = "$(plutil -extract NSServices.0.NSPortName raw "$plist")" ] \
    || die "NSServices' NSPortName must equal CFBundleName."

# --- Sign -----------------------------------------------------------------------------------------------------
sign_flags=(--force --options runtime --sign "$identity")
if [ "$identity" = "-" ]; then sign_flags+=(--timestamp=none); else sign_flags+=(--timestamp); fi

# The command-line tool first, without the sandbox: the user runs it from Terminal with their own permissions
# (any path they name), and a sandboxed helper launched outside the app couldn't open those files.
codesign "${sign_flags[@]}" --identifier "$CLI_ID" "$contents/Helpers/imageconverter"
# The installer service, without entitlements: not sandboxed (see above).
codesign "${sign_flags[@]}" --identifier "$INSTALLER_ID" "$xpc"
# Then the app (which seals the helper and the service), sandboxed.
codesign "${sign_flags[@]}" --identifier "$BUNDLE_ID" --entitlements Resources/imageconverter.entitlements "$app"

codesign --verify --strict --deep --verbose=2 "$app"
codesign -d --entitlements - --xml "$app" 2>/dev/null > "$work/entitlements.plist"
# PlistBuddy, not plutil -extract: the key's dots would be read as a key path.
[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$work/entitlements.plist" 2>/dev/null)" = "true" ] \
    || die "the signed app has no App Sandbox entitlement."
# Network: client only (the update check and download), never a server entitlement.
[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.network.client" "$work/entitlements.plist" 2>/dev/null)" = "true" ] \
    || die "the signed app has no network client entitlement (needed for the update check)."
grep -q "com.apple.security.network.server" "$work/entitlements.plist" && die "the signed app has a network server entitlement."
# Exactly these four entitlements, nothing else (no temporary exceptions).
entitlement_keys=$(plutil -p "$work/entitlements.plist" | sed -n 's/^  "\(.*\)" => .*/\1/p' | sort | tr '\n' ' ')
[ "$entitlement_keys" = "com.apple.security.app-sandbox com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write com.apple.security.network.client " ] \
    || die "the signed app's entitlements are not exactly the expected four: $entitlement_keys"
cli_entitlements=$(codesign -d --entitlements - --xml "$contents/Helpers/imageconverter" 2>/dev/null || true)
grep -q "app-sandbox" <<< "$cli_entitlements" && die "the command-line helper must not be sandboxed."
[ -d "$xpc" ] || die "the installer service is missing."
codesign --verify --strict --verbose=2 "$xpc" || die "the installer service's signature does not verify."
[ "$(plutil -extract CFBundlePackageType raw "$xpc_plist")" = 'XPC!' ] || die "the installer service is not an XPC bundle."
[ "$(plutil -extract XPCService.ServiceType raw "$xpc_plist")" = Application ] || die "the installer service's type is not Application."
# Captured first: with pipefail, `grep -q` closing the pipe early could fail the pipeline and hide a match.
xpc_info=$(codesign -d --verbose=2 "$xpc" 2>&1)
grep -qx "Identifier=$INSTALLER_ID" <<< "$xpc_info" || die "the installer service's identifier is not $INSTALLER_ID."
xpc_entitlements=$(codesign -d --entitlements - --xml "$xpc" 2>/dev/null || true)
grep -q "app-sandbox" <<< "$xpc_entitlements" && die "the installer service must not be sandboxed."
echo "==> signed and verified: sandbox on, network client only (no server); installer service unsandboxed"
if [ "$skip_appintents" = true ]; then
    [ ! -e "$contents/Resources/Metadata.appintents" ] || die "SKIP_APPINTENTS=1 but the app has a Metadata.appintents."
    echo "==> Shortcuts actions: none (App Intents metadata skipped, SKIP_APPINTENTS=1)"
else
    [ -f "$contents/Resources/Metadata.appintents/extract.actionsdata" ] || die "the signed app has no Metadata.appintents."
    echo "==> Shortcuts actions: ${intents[*]}"
fi

# --- Zip (and notarize) ---------------------------------------------------------------------------------------
if [ "$notarize" = true ]; then
    zip_name="$APP_NAME-$version.zip"
    ditto -c -k --keepParent "$app" "$work/submit.zip"
    echo "==> submitting to the notary service (profile $NOTARY_PROFILE)"
    xcrun notarytool submit "$work/submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
        > "$work/notary.json" || true
    cat "$work/notary.json"; echo
    submission=$(plutil -extract id raw "$work/notary.json" 2>/dev/null || true)
    status=$(plutil -extract status raw "$work/notary.json" 2>/dev/null || true)
    if [ "$status" != "Accepted" ]; then
        if [ -n "$submission" ]; then
            xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" || true
        fi
        die "notarization was not accepted (status: ${status:-unknown}, submission: ${submission:-none})."
    fi
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
elif [ "$identity" = "-" ]; then
    zip_name="$APP_NAME-$version-unsigned-adhoc.zip"
else
    zip_name="$APP_NAME-$version-not-notarized.zip"
fi
ditto -c -k --keepParent "$app" "$work/$zip_name"
(cd "$work" && shasum -a 256 "$zip_name" > "$zip_name.sha256")

# Done: replace the previous results (including zips of other versions or modes) with this run's.
rm -rf "${dist:?}/$APP_NAME.app"
rm -f "$dist/$APP_NAME"-*.zip "$dist/$APP_NAME"-*.zip.sha256
mv "$work/$APP_NAME.app" "$work/$zip_name" "$work/$zip_name.sha256" "$dist/"
app="$dist/$APP_NAME.app"
zip="$dist/$zip_name"

echo "==> $app"
echo "==> $zip"
cat "$zip.sha256"
