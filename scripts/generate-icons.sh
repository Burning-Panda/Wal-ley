#!/bin/sh
# Renders design/icon.svg into every macOS app icon size.
# Needs rsvg-convert:  brew install librsvg
set -eu

cd "$(dirname "$0")/.."

SVG="design/icon.svg"
OUT="wal-ley/Assets.xcassets/AppIcon.appiconset"

command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert not found (brew install librsvg)" >&2; exit 1; }

for px in 16 32 64 128 256 512 1024; do
    rsvg-convert -w "$px" -h "$px" "$SVG" -o "$OUT/icon_$px.png"
    echo "icon_$px.png"
done
