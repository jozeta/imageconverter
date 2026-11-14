#!/usr/bin/env bash
# Builds dist/imageconverter.app (universal, sandboxed, hardened runtime) with the command-line tool inside at
# Contents/Helpers/imageconverter, signs it and zips it.
#
# Usage: scripts/release.sh [--notarize]
#
# Environment:
#   SIGN_IDENTITY   codesign identity (default "-": ad hoc, for local testing; nothing is notarized)
#   NOTARY_PROFILE  notarytool keychain profile (`xcrun notarytool store-credentials`); needed for --notarize
#
# Results: dist/imageconverter.app and
#   dist/imageconverter-<version>.zip              signed with a Developer ID, notarized and stapled (--notarize)
#   dist/imageconverter-<version>-not-notarized.zip  signed with a real identity, not notarized
#   dist/imageconverter-<version>-unsigned-adhoc.zip ad hoc signature (runs only on this Mac without a warning)
# each with a .sha256 file next to it. Credentials stay in the keychain; none are read or printed here.
set -euo pipefail

BUNDLE_ID="io.github.jozeta.imageconverter"
CLI_ID="$BUNDLE_ID.cli"
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
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option '$argument' (usage: scripts/release.sh [--notarize])" ;;
    esac
done

identity="${SIGN_IDENTITY:--}"
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

echo "==> imageconverter $version (build $build), identity: $([ "$identity" = "-" ] && echo "ad hoc" || echo "$identity")"

# --- Build ----------------------------------------------------------------------------------------------------
dist="$root/dist"
mkdir -p "$dist"
# Everything is assembled in here and moved into dist/ only once it is signed and verified, so a failed run never
# leaves a finished-looking app behind. Inside dist/ so the final move stays on one volume.
work=$(mktemp -d "$dist/.release-XXXXXX")
trap 'rm -rf "$work"' EXIT

universal=(-c release --arch arm64 --arch x86_64)
build_log="$work/build.log"
if swift build "${universal[@]}" --product "$EXECUTABLE" 2>&1 | tee "$build_log" \
    && swift build "${universal[@]}" --product imageconverter-cli 2>&1 | tee -a "$build_log"; then
    bin=$(swift build "${universal[@]}" --show-bin-path)
elif grep -Eiq "unable to find utility \"?xcbuild|xcbuild.*not found|requires xcode|multiple (--arch|architectures).*not supported" "$build_log"; then
    # Only a toolchain that can't build a second architecture (Command Line Tools without Xcode) falls back.
    warn "this toolchain can't build a universal binary (needs Xcode); building for $(uname -m) only."
    swift build -c release --product "$EXECUTABLE"
    swift build -c release --product imageconverter-cli
    bin=$(swift build -c release --show-bin-path)
else
    die "the release build failed (see the errors above)."
fi
[ -x "$bin/$EXECUTABLE" ] && [ -x "$bin/imageconverter-cli" ] || die "built products not found in $bin."

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
printf 'APPL????' > "$contents/PkgInfo"

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
# Then the app (which seals the helper), sandboxed.
codesign "${sign_flags[@]}" --identifier "$BUNDLE_ID" --entitlements Resources/imageconverter.entitlements "$app"

codesign --verify --strict --deep --verbose=2 "$app"
codesign -d --entitlements - --xml "$app" 2>/dev/null > "$work/entitlements.plist"
# PlistBuddy, not plutil -extract: the key's dots would be read as a key path.
[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$work/entitlements.plist" 2>/dev/null)" = "true" ] \
    || die "the signed app has no App Sandbox entitlement."
grep -q "com.apple.security.network" "$work/entitlements.plist" && die "the signed app has a network entitlement."
codesign -d --entitlements - --xml "$contents/Helpers/imageconverter" 2>/dev/null | grep -q "app-sandbox" \
    && die "the command-line helper must not be sandboxed."
echo "==> signed and verified: sandbox on, no network entitlement"

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
