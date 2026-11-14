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
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]] \
    || die "VERSION '$version' is not a semantic version (x.y.z)."
build=$(git rev-list --count HEAD 2>/dev/null) || die "can't count commits for CFBundleVersion (not a git checkout?)."

# The command-line tool finds the app's container by this identifier; both must agree.
grep -q "bundleIdentifier = \"$BUNDLE_ID\"" Sources/ImageconverterCLIKit/CLIDataDirectory.swift \
    || die "BUNDLE_ID ($BUNDLE_ID) differs from CLIDataDirectory.bundleIdentifier."

echo "==> imageconverter $version (build $build), identity: $([ "$identity" = "-" ] && echo "ad hoc" || echo "$identity")"

# --- Build ----------------------------------------------------------------------------------------------------
if swift build -c release --arch arm64 --arch x86_64 --product "$EXECUTABLE" \
    && swift build -c release --arch arm64 --arch x86_64 --product imageconverter-cli; then
    bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
    warn "universal build failed (needs Xcode); building for $(uname -m) only."
    swift build -c release --product "$EXECUTABLE"
    swift build -c release --product imageconverter-cli
    bin=$(swift build -c release --show-bin-path)
fi
[ -x "$bin/$EXECUTABLE" ] && [ -x "$bin/imageconverter-cli" ] || die "built products not found in $bin."

# --- Assemble -------------------------------------------------------------------------------------------------
dist="$root/dist"
app="$dist/$APP_NAME.app"
contents="$app/Contents"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

rm -rf "$app"
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
plutil -replace NSHumanReadableCopyright -string "Copyright © $(date +%Y) Johan Zetterström. MIT License." "$plist"
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
    zip="$dist/$APP_NAME-$version.zip"
    ditto -c -k --keepParent "$app" "$work/submit.zip"
    echo "==> submitting to the notary service (profile $NOTARY_PROFILE)"
    xcrun notarytool submit "$work/submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
elif [ "$identity" = "-" ]; then
    zip="$dist/$APP_NAME-$version-unsigned-adhoc.zip"
else
    zip="$dist/$APP_NAME-$version-not-notarized.zip"
fi
rm -f "$zip" "$zip.sha256"
ditto -c -k --keepParent "$app" "$zip"
(cd "$dist" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")

echo "==> $app"
echo "==> $zip"
cat "$zip.sha256"
