#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
APP="packaging/Pesty-Alvie.app"
DMG="packaging/Pesty-Alvie-$VERSION.dmg"
ENTITLEMENTS="packaging/Pesty-Alvie.entitlements"

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
: "${ASC_KEY:?Set ASC_KEY to your App Store Connect API key path}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect key ID}"
: "${ASC_ISSUER:?Set ASC_ISSUER to your App Store Connect issuer ID}"

[ -d "$APP" ] || { echo "Missing $APP — run build_app.sh first"; exit 1; }

echo "==> Codesigning app (hardened runtime)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP/Contents/MacOS/Pesty-Alvie"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing app"
ZIP="packaging/Pesty-Alvie.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
    --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> Building DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Pesty-Alvie.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pesty-Alvie" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "==> Signing + notarizing DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" \
    --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
    --wait
xcrun stapler staple "$DMG"

echo "==> Gatekeeper assessment"
spctl -a -vvv -t install "$DMG" || true
codesign -dvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier" || true

shasum -a 256 "$DMG"
echo "==> Done: $DMG"
