#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/assets/MBJFW-AppIcon-1024.png"
OUTPUT="$ROOT/assets/AppIcon.icns"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mbjfw-icon.XXXXXX")
ICONSET="$WORK/MBJFW.iconset"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$ICONSET"

make_size() {
    size=$1
    name=$2
    /usr/bin/sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/$name" >/dev/null
}

make_size 16 icon_16x16.png
make_size 32 icon_16x16@2x.png
make_size 32 icon_32x32.png
make_size 64 icon_32x32@2x.png
make_size 128 icon_128x128.png
make_size 256 icon_128x128@2x.png
make_size 256 icon_256x256.png
make_size 512 icon_256x256@2x.png
make_size 512 icon_512x512.png
make_size 1024 icon_512x512@2x.png
/usr/bin/iconutil --convert icns --output "$OUTPUT" "$ICONSET"
echo "Created $OUTPUT"
