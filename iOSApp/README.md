# Pesty-Alvie Companion for iPhone and iPad

This is an isolated iOS 17+ SwiftUI app. It deliberately has no build-time or
source dependency on the existing macOS application.

## What works now

- Local clip library, search, type filtering, pinboards, copy-back, and share.
- A manual `store.json` importer for a Pesty-Alvie library exported through iCloud
  Drive. Text, links, colors, and pinboard membership import immediately.
- Portable companion-domain models with stable IDs, update timestamps, and
  deletion tombstones so they can later be backed by shared CloudKit records.
- iCloud account readiness UI and the required CloudKit entitlement.

## What deliberately waits for the Mac bridge

The current macOS app stores its library in a macOS iCloud Drive folder; it
does not write a shared CloudKit record set. Therefore no iOS-only change can
produce live Mac-to-iPhone history yet. A future Mac change should implement
the same record-level CloudKit sync protocol and upload image/RTF assets.

## Open and test

Open `Pesty-Alvie.xcodeproj` in Xcode, select a development team, and
register and enable the `iCloud.com.alvst.pesty-alvie` CloudKit container before testing
CloudKit on a physical device.

```bash
cd iOSApp
xcodegen generate --spec project.yml
xcodebuild test \
  -project Pesty-Alvie.xcodeproj \
  -scheme Pesty-Alvie \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/Pesty-AlvieTestData \
  CODE_SIGNING_ALLOWED=NO
```
