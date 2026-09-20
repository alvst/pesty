#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ICON_OUTPUT="packaging/Pesty.icns"
if [[ -f "$ICON_OUTPUT" && "${FORCE_ICON_REBUILD:-0}" != "1" ]]; then
  echo "using tracked $ICON_OUTPUT"
  exit 0
fi

mkdir -p packaging

ICON_SOURCE="packaging/icon_1024.png"
if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "missing $ICON_SOURCE" >&2
  exit 1
fi

ICONSET="packaging/Pesty.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

gen() { sips -z "$1" "$1" "$ICON_SOURCE" --out "$ICONSET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

python3 scripts/make_icns.py "$ICONSET" "$ICON_OUTPUT"
echo "wrote $ICON_OUTPUT"
