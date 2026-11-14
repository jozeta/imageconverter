#!/bin/sh
# Turns the 1024 px app icon PNG into a macOS .icns (all sizes 16…512 @1x and @2x).
# Usage: scripts/make-iconset.sh Resources/AppIcon.png dist/AppIcon.icns
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <icon-1024.png> <out.icns>" >&2
    exit 64
fi
src=$1
out=$2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir "$iconset"

for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$src" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p "$(dirname "$out")"
iconutil -c icns "$iconset" -o "$out"
echo "wrote $out"
