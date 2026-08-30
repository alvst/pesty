#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-2.0.0}"
BUILD="${BUILD:-5}"
APP="packaging/Pesty-Alvie.app"
PKG="packaging/Pesty-Alvie-MAS-$VERSION.pkg"
ENT_TEMPLATE="packaging/Pesty-Alvie-MAS.entitlements"
PROFILE="${PROFILE:-packaging/Pesty-Alvie_MAS.provisionprofile}"
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
: "${APP_IDENTITY:?Set APP_IDENTITY to your Apple Distribution identity}"
: "${INSTALLER_IDENTITY:?Set INSTALLER_IDENTITY to your installer signing identity}"

RESOLVED_ENT="$(mktemp -t pesty-alvie-entitlements)"
trap 'rm -f "$RESOLVED_ENT"' EXIT
sed "s/__TEAM_ID__/$TEAM_ID/g" "$ENT_TEMPLATE" > "$RESOLVED_ENT"

[ -f "$PROFILE" ] || { echo "Missing provisioning profile at $PROFILE"; exit 1; }

echo "==> Building universal release binary (sandboxed, no Accessibility — MAS flag)"
swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DMAS --product Pesty-Alvie
BIN="$(swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DMAS --show-bin-path)/Pesty-Alvie"
bash scripts/make_icon.sh >/dev/null

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pesty-Alvie"
cp packaging/Pesty-Alvie.icns "$APP/Contents/Resources/Pesty-Alvie.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "==> Signing for the Mac App Store (sandboxed)"
codesign --force --timestamp --entitlements "$RESOLVED_ENT" --sign "$APP_IDENTITY" "$APP/Contents/MacOS/Pesty-Alvie"
codesign --force --timestamp --entitlements "$RESOLVED_ENT" --sign "$APP_IDENTITY" "$APP"

echo "==> Building signed installer package"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"

echo "==> Verification"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "--- sandbox entitlement ---"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -A1 "app-sandbox" || \
  codesign -d --entitlements - "$APP" 2>/dev/null | plutil -p - 2>/dev/null | grep -i sandbox || true
echo "--- pkg signature ---"
pkgutil --check-signature "$PKG" | head -8
echo "==> Done: $PKG"
