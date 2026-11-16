#!/usr/bin/env bash
# Regenerates the README screenshots in docs/screenshots/*.png.
#
# Builds the DEBUG app, launches it once per screenshot with its own settings (`-debugDefaultsSuite readme`, so your real
# settings, presets, jobs and history are never touched), the generated sample images in docs/screenshots/samples and the
# prepared pipelines in docs/screenshots/pipelines, captures the app window by its window id (`screencapture -l`, no
# shadow; it works even when other windows cover it) and quits the app. PNGs are scaled to 1300 px wide and their colours
# reduced until they are 400 KB or less (scripts/shrink-png.swift, Apple frameworks only); over 500 KB is a warning.
#
# Needs: Screen Recording permission for your terminal, and a free main display (don't use the Mac while it runs: the app
# windows open on the current Space). Usage: scripts/screenshots.sh [name ...]   (no names: all)
# The sample images come from scripts/make-sample-images.swift; the Jobs shot uses the files in docs/screenshots/jobs.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
shots="$root/docs/screenshots"
suite=readme
work=/tmp/imageconverter-readme
scratch="${TMPDIR:-/tmp}/imageconverter-$suite"    # where DEBUG builds keep a suite's presets, jobs, history
binary="$root/.build/debug/Imageconverter"
only=("$@")
pid=""

cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    defaults delete "$suite" >/dev/null 2>&1 || true
    rm -rf "$work" "$scratch"
}
trap cleanup EXIT

die() { echo "screenshots.sh: $*" >&2; exit 1; }
wanted() { [ ${#only[@]} -eq 0 ] && return 0; local n; for n in "${only[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }

swift build >/dev/null || die "build failed"
rm -rf "$work" "$scratch"
mkdir -p "$work/Photos" "$work/Inbox" "$work/Web" "$work/Archive" "$work/Out"
cp "$shots"/samples/* "$work/Photos/"
photos=("$work/Photos/sunset.jpg" "$work/Photos/meadow.jpg" "$work/Photos/night.jpg" "$work/Photos/rings.jpg"
        "$work/Photos/shapes.png" "$work/Photos/located.jpg")
cp "$shots/samples/sunset.jpg" "$work/Inbox/"

# Scales to the window's size in points and reduces the colours until the file is 400 KB or less; if the script
# fails, sips only scales (bigger files).
shrink() {
    if ! swift "$root/scripts/shrink-png.swift" "$1"; then
        sips -Z 1300 "$1" >/dev/null
    fi
}

# shot <name> <pipeline> [defaults key=value ...] -- <app arguments> [-- <window title>]
# Starts from empty settings, writes the pipeline and the settings, launches the app, captures, quits.
shot() {
    local name=$1 pipeline=$2; shift 2
    wanted "$name" || return 0
    local settings=() args=() title=""
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do settings+=("$1"); shift; done
    shift
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do args+=("$1"); shift; done
    [ $# -gt 0 ] && title=${2:-}
    defaults delete "$suite" >/dev/null 2>&1 || true
    defaults write "$suite" currentPipeline -data "$(xxd -p "$shots/pipelines/$pipeline.json" | tr -d '\n')"
    defaults write "$suite" outputModeKind newFolder
    defaults write "$suite" outputFolder "$work/Out"
    defaults write "$suite" updateCheckOnLaunch -bool false    # no first-launch question, never online
    local pair
    for pair in ${settings[@]+"${settings[@]}"}; do defaults write "$suite" "${pair%%=*}" "${pair#*=}"; done
    "$binary" -debugDefaultsSuite "$suite" "${args[@]}" >/dev/null 2>&1 &
    pid=$!
    local id="" tries=0
    while [ -z "$id" ] && [ $tries -lt 40 ]; do
        sleep 0.5; tries=$((tries + 1))
        id=$(swift scripts/window-id.swift "$pid" ${title:+"$title"} 2>/dev/null || true)
    done
    [ -n "$id" ] || die "$name: no window appeared"
    sleep 4    # previews, thumbnails and sheets settle
    id=$(swift scripts/window-id.swift "$pid" ${title:+"$title"})
    screencapture -o -x -l "$id" "$shots/$name.png"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
    shrink "$shots/$name.png"
    echo "captured $name.png ($(( $(stat -f %z "$shots/$name.png") / 1024 )) KB)"
}

size=(-debugWindowWidth 1300 -debugWindowHeight 960)
files=(-debugAddFiles "${photos[@]}")

# The batch is listed by name: 0 located (GPS and serial number), 1 meadow, 2 night, 3 rings, 4 shapes (transparent), 5 sunset.
shot main main -- -debugSelect 5 "${size[@]}" "${files[@]}"
shot compare-split main compareMode=split -- -debugSelect 1 "${size[@]}" "${files[@]}"
shot quality main -- -debugSelect 5 -debugShowQuality "${size[@]}" "${files[@]}"
shot pipeline watermark -- -debugSelect 5 -debugExpandSteps "${size[@]}" "${files[@]}"
shot adjust adjust -- -debugSelect 1 -debugExpandSteps "${size[@]}" "${files[@]}"
shot output-target-size output -- -debugSelect 5 "${size[@]}" "${files[@]}"
shot outputs outputs -- -debugSelect 5 -debugExpandSteps -debugShowEstimateInfo "${size[@]}" "${files[@]}"
shot metadata metadata -- -debugSelect 0 -debugExpandSteps "${size[@]}" "${files[@]}"
shot rename rename -- -debugSelect 5 -debugExpandSteps "${size[@]}" "${files[@]}"
shot condition condition -- -debugSelect 0 -debugExpandSteps "${size[@]}" "${files[@]}"
shot privacy main -- -debugSelect 0 -debugShowPrivacyPanel "${size[@]}" "${files[@]}"

# Jobs: two prepared jobs, pointing at the temporary folders.
if wanted jobs; then
    mkdir -p "$work/jobs"
    for f in "$shots"/jobs/*.json; do sed "s|@WORK@|$work|g" "$f" > "$work/jobs/$(basename "$f")"; done
    shot jobs main -- -debugJobsDirectory "$work/jobs" -debugShowJobs -debugWindowWidth 900 -debugWindowHeight 600 -- Jobs
fi

# History: run one batch first (a launch with -debugAutoRun), then open the History window.
if wanted history; then
    defaults delete "$suite" >/dev/null 2>&1 || true
    defaults write "$suite" currentPipeline -data "$(xxd -p "$shots/pipelines/watermark.json" | tr -d '\n')"
    defaults write "$suite" outputModeKind newFolder
    defaults write "$suite" outputFolder "$work/Out"
    defaults write "$suite" updateCheckOnLaunch -bool false    # no first-launch question, never online
    "$binary" -debugDefaultsSuite "$suite" -debugAutoRun "${files[@]}" >/dev/null 2>&1 &
    pid=$!; sleep 12; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pid=""
    shot history main -- -debugShowHistory -- History
fi

shot about main -- -debugShowAbout -- About

# Keep the images small: a screenshot over 500 KB is a bug in this script, not something to commit.
for f in "$shots"/*.png; do
    [ "$(stat -f %z "$f")" -le 512000 ] || echo "warning: $(basename "$f") is over 500 KB" >&2
done
