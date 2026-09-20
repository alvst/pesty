<div align="center">

<img src="docs/assets/icon.png" width="128" alt="Pesty icon" />

# Pesty

**This is an independently maintained fork of [momenbasel/pesty](https://github.com/momenbasel/pesty).**

Your clipboard history as a beautiful, color-coded strip that slides up from the bottom of your screen.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple)
![Universal](https://img.shields.io/badge/Universal-Apple%20Silicon%20%2B%20Intel-orange?style=flat-square)

[**Upstream repository**](https://github.com/momenbasel/pesty) · [Build locally](#build-from-source)

<sub>Release plan: macOS 2.0.0 first; the iPhone/iPad companion plus Mac↔iOS sync, widget, and share extension remain planned for 2.5.0.</sub>

<img src="docs/assets/demo.gif" width="820" alt="Pesty clipboard manager demo - color-coded clipboard strip with keyboard navigation on macOS" />

### ⭐ If Pesty helped you, consider starring the [upstream project](https://github.com/momenbasel/pesty).

</div>

## What is Pesty?

Pesty keeps a history of everything you copy and lets you get it back instantly. Hit a global hotkey, the strip slides up, you pick a clip with the arrow keys (or `⌘1`–`⌘9`), press `return`, and it pastes straight into whatever app you were in.

It is a native reimplementation of the Paste experience, built in **Swift + SwiftUI** with **zero third-party dependencies**.

## Features

- **Slide-up strip** - a full-width, translucent panel that springs up from the bottom of the active screen, with a compact menu-bar companion.
- **Color-coded cards** - source-app icons, adaptive app-derived colors, type labels, timestamps, previews, character counts, and numbered quick-paste affordances. The new **Default** style adapts to the icon; **Classic** keeps the original fixed palette.
- **All content types** - plain text, rich text, links, images, files, and colors, with native previews where possible.
- **Paste Stacks** - collect, reorder, rename, and paste a temporary group of clips, then save or clear the stack.
- **Pinboards** - save clips into named, color-tagged collections that do not expire; drag to reorder and switch boards from the strip.
- **Paste-library import** - import an installed Paste SQLite library from Settings, including history, timestamps, source apps, supported payloads, and pinboards. Import is additive and de-duplicates existing clips.
- **Mac sync** - direct builds can sync Macs through iCloud Drive; sandboxed builds use private CloudKit records. Interoperability with the iPhone/iPad companion remains planned.
- **Instant search** - start typing to filter history, stacks, and the selected pinboard.
- **Keyboard-first** - arrow keys move selection, `return` pastes, `⌘1`–`⌘9` quick-paste, `⌘⌫` deletes, and `esc` clears search or closes the strip.
- **Paste directly or to the clipboard** - paste into the active app through Accessibility, or copy selected clips for manual pasting; an optional “Always paste as Plain Text” mode is available.
- **Privacy controls** - respect concealed, confidential, and transient pasteboard markers; ignore selected applications; pause capture; control visibility during screen sharing; and keep local history files private.
- **Link-preview controls** - optionally fetch link metadata and show inline/native previews, with a setting to disable network preview requests.
- **Custom source icons** - choose separate Light and Dark icons for recognized applications (including custom ChatGPT/Codex icon mappings); system-only sources such as `loginwindow` are hidden.
- **Appearance settings** - light/dark-aware card surfaces, text, previews, and custom icons, plus Default/Classic color styles and accent shades.
- **Convenience settings** - configurable global shortcut, launch at login, sound feedback, card/strip sizing, history retention, clear-history controls, and an Extensions area for JavaScript clip actions.
- **Native & light** - a universal Swift/SwiftUI `.app` with no Electron runtime or background web stack.

## Install

Build this fork from source below. The result is `packaging/Pesty.app`.

## First run

1. Press **`⌃⌘V`** (this fork's default shortcut) to open the strip.
2. Pick a clip and press `return`.
   - **Direct build:** the first time you paste, macOS asks for **Accessibility** permission - grant it separately to Pesty so it can paste directly into other apps. You can change this anytime in **System Settings → Privacy & Security → Accessibility**.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `⌃⌘V` | Show / hide the strip (configurable) |
| `←` `→` `↑` `↓` | Move selection |
| `return` | Leave search editing; otherwise paste selected clip |
| `⌘1`–`⌘9` | Quick-paste the Nth clip |
| `⌘⌫` | Delete selected clip |
| `⌘S` in Preview | Save a copy of the previewed clip to a file |
| `⌘O` in Preview | Open the previewed image, text, or link in its configured app |
| type anything | Search |
| `esc` | Clear search, then close |

## Build from source

Requires macOS 14+ and a Swift 6 toolchain. The macOS 2.0.0 build and the
separate iOS 2.5.0 development project are pinned to Xcode 26.3.

```bash
git clone https://github.com/alvst/pesty.git
cd pesty
swift run Pesty # run in place
# or build a distributable .app:
VERSION=2.0.0 BUILD=1 ./scripts/build_app.sh
open packaging/Pesty.app
```

To produce a signed + notarized DMG (needs a Developer ID cert and an App Store Connect API key):

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_XXXX.p8" \
ASC_KEY_ID="XXXX" ASC_ISSUER="<issuer-uuid>" \
./scripts/release_build.sh
```

## Project structure

```
Sources/Pesty/
  Main.swift            entry point
  AppController.swift   app delegate, hotkey + menu-bar wiring, paste flow
  Models/               ClipItem, ClipType, Pinboard
  Store/                ClipboardStore (history, pinboards, persistence, Paste import)
  Sync/                 shared CloudKit schema, codecs, and MAS sync engine
  Monitor/              ClipboardMonitor (pasteboard polling), PasteService (⌘V injection)
  Hotkey/               HotKeyCenter (Carbon global hotkey)
  UI/                   BarView, ClipCardView, PinboardTabs, the sliding panel
  Settings/             Settings store + preferences window + hotkey recorder
  Util/                 icons, color hex, visual-effect view, launch-at-login
scripts/                build, icon, sign + notarize
packaging/              Info.plist, entitlements, generated artifacts
iOSApp/                 planned 2.5.0 companion, widget/share targets, and tests
```

## Pesty vs other Mac clipboard managers

| | Pesty | Paste | Maccy |
| --- | --- | --- | --- |
| Price | **Free** | Subscription | Free |
| Open source | **Yes (MIT)** | No | Yes |
| Color-coded strip UI | Yes | Yes | No (list) |
| Pinboards | Yes | Yes | No |
| Source-app color coding | Yes | Yes | No |
| Native (no Electron) | Yes | Yes | Yes |
| Signed & notarized | When built with your Developer ID | Yes | Yes |

This fork retains Pesty's native slide-up strip, color-coded cards, pinboards, search, and keyboard-driven pasting while continuing development independently.

## FAQ

**Is Pesty free?** Yes. It remains covered by Pesty's MIT license.

**How does this relate to upstream Pesty?** It is an independently maintained fork that keeps the Pesty app, package, executable, and repository names for compatibility.

**Can I bring over my Paste library?** Yes. Open **Settings → General → Import from Paste…** and choose the Paste database (the default location is detected automatically when Paste is installed). The importer reads supported history payloads and pinboards without modifying the original database; duplicate clips are skipped.

**Does it keep my clipboard private?** Direct builds store clips locally or in your selected iCloud Drive folder. Sandboxed Mac builds use your private CloudKit database; synchronization with the companion is part of the planned 2.5.0 release. Clipboard contents are not logged; password-manager clips and locally excluded source apps are ignored. Link metadata previews can make network requests.

**What macOS does it need?** macOS 14 (Sonoma) or later, on Apple Silicon or Intel.

> **Keywords:** clipboard manager for Mac, macOS clipboard history, free Paste app alternative, open-source clipboard manager, Maccy alternative, copy-paste history, clipboard pinboards.

## Contributing

PRs welcome - see [CONTRIBUTING.md](CONTRIBUTING.md). Good first issues include more content-type renderers and focused accessibility or test improvements.

## License

[MIT](LICENSE) © 2026 Moamen Basel.

## Disclaimer

This repository is an independently maintained fork of [momenbasel/pesty](https://github.com/momenbasel/pesty), originally created by Moamen Basel, and remains under the MIT License. Neither project is affiliated with, endorsed by, or connected to Paste or its makers (Wonder Warp / FIPLAB). All trademarks belong to their respective owners.
