#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
APP="packaging/Pesty-Alvie.app"

echo "==> Building universal release binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --product Pesty-Alvie

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Pesty-Alvie"
echo "    binary: $BIN"

echo "==> Generating icon"
bash scripts/make_icon.sh >/dev/null

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pesty-Alvie"
cp packaging/Pesty-Alvie.icns "$APP/Contents/Resources/Pesty-Alvie.icns"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    packaging/Info.plist > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Explicitly sign the assembled bundle with a stable designated requirement.
# Without this, each release build only carries Swift's per-binary linker
# signature (a changing CDHash), which makes macOS ask for Accessibility again.
echo "==> Signing $APP"
/usr/bin/codesign --force --sign - --identifier com.alvst.pesty-alvie \
  -r='designated => identifier "com.alvst.pesty-alvie"' "$APP"

echo "==> Built $APP"
/usr/bin/file "$APP/Contents/MacOS/Pesty-Alvie"
echo "    version $VERSION ($BUILD)"
