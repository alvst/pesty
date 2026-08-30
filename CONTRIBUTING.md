# Contributing to Pesty-Alvie

Thanks for your interest. Pesty-Alvie is a small, native macOS app with no third-party dependencies, so it's easy to get into.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 26.3 for the pinned Mac/iOS matrix

## Build and run

```bash
git clone https://github.com/alvst/pesty.git
cd pesty
swift build                    # compile
swift run Pesty-Alvie          # run in place
swift run Pesty-Alvie --demo   # run with sample clips and the strip open (for UI work)
swift test                     # macOS unit tests
swift build -Xswiftc -DMAS     # sandboxed/CloudKit compile check
```

To build a distributable bundle:

```bash
VERSION=2.0.0 BUILD=1 ./scripts/build_app.sh
open packaging/Pesty-Alvie.app
```

## Architecture

- `ClipboardMonitor` polls `NSPasteboard` and turns new contents into `ClipItem`s.
- `ClipboardStore` is the single `@Observable` source of truth (history + pinboards + selection + search) and owns JSON persistence.
- `AppController` wires the global hotkey, the menu-bar item, the sliding panel, and the paste flow.
- `BarWindowController` is a borderless `NSPanel` that slides up from the bottom; it hosts `BarView`.
- `PasteService` writes a clip back to the pasteboard and synthesizes `⌘V` into the previously-active app.

## Guidelines

- Keep it dependency-free. Prefer system frameworks (AppKit, SwiftUI, Carbon, ServiceManagement).
- Match the existing style. Small, focused changes; no unrelated refactors in the same PR.
- Test on both Apple Silicon and Intel where it matters (the release is universal).
- UI changes: include before/after screenshots of the full strip. A change with
  no visual delta may omit screenshots only when the PR explicitly says that
  it has no visual delta.

## Pull requests

1. Fork and branch from `main`.
2. Make your change; run `swift test`, `swift build -Xswiftc -DMAS`, the iOS
   simulator tests when relevant, and `git diff --check`.
3. Open a PR with a clear description and before/after screenshots for visual
   changes, or an explicit no-visual-delta statement when screenshots do not
   apply.

## Good first issues

- Large preview pane for the selected clip
- Drag-and-drop out of a card
- Resize handle on the strip (Paste-style)
- Richer renderers (RTF, link previews with favicons)

## Code of conduct

Be kind. We follow the [Contributor Covenant](https://www.contributor-covenant.org/).
