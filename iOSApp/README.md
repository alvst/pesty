# Pesty-Alvie 2.5 Companion for iPhone and iPad

This is the in-development iOS 17+ SwiftUI companion for the planned 2.5.0
release. It has the same private CloudKit record contract as the sandboxed
macOS build. The targets share no source dependency; their two copies of
`CloudKitSchema.swift` must remain byte-identical.

## Release boundary

The companion app, its widget and share extension, and all Mac↔iOS CloudKit
synchronization ship on the 2.5.0 train. They are not part of the macOS 2.0.0
release or the upstream-aligned 2.1.0 Paste Stacks release. Until the 2.5.0
release gates below pass, this directory is development source rather than a
released companion.

## What is implemented for 2.5.0

- Bidirectional private-database sync for text, rich text, links, colors,
  images, file metadata, Pinboard membership/order, edits, and hard deletes.
- Offline changes and change tokens persisted with `CKSyncEngine`.
- Local clip creation, photo import, search, type filtering, Pinboards,
  copy-back, and sharing.
- A manual `store.json` importer for a Pesty-Alvie library exported through iCloud
  Drive. It repairs legacy shared IDs into stable, per-Pinboard copies.
- Five-minute local Undo for clip deletions. CloudKit keeps the last active
  record during the grace period and sends the hard delete only after expiry.
- Owner-only local persistence, bounded CloudKit assets, and local-cache erase.

## Sync boundary

The Mac App Store (`MAS`) build uses CloudKit for its Mac records.
Interoperability with this companion begins with 2.5.0. The direct-download Mac
build continues to offer iCloud Drive sync between Macs and does not talk to
the companion. The iOS simulator intentionally runs as a local-only library;
entitlement and push behavior must be tested with a signed physical-device
build.

## Open and test

Signing is configured per checkout so contributor team IDs never enter the
shared project. Copy `Config/Signing.local.xcconfig.example` to
`Config/Signing.local.xcconfig`, replace `YOUR_TEAM_ID`, and regenerate the
project. The local file is ignored by Git and applies to every app and
extension target.

Open `Pesty-Alvie.xcodeproj` in Xcode 26.3 and use automatic signing. In the
Apple Developer portal, register the
`com.alvst.pesty-alvie.companion` App ID, enable iCloud/CloudKit and push
notifications, and assign `iCloud.com.alvst.pesty-alvie`. The sandboxed Mac App
ID must be assigned the same container. After validating the Development
environment on two devices, deploy its schema to Production in CloudKit
Console before distributing either app.

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

The unsigned simulator suite verifies local behavior and record encoding. The
2.5.0 release gate still requires a real iPhone/iPad and a provisioned Mac to
prove account status, push delivery, offline convergence, conflict handling,
images, and deletes against the actual container.
