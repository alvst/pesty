# Quick Look navigation bug in Pesty — debugging notes

Written after a long session where a Quick Look dismiss/selection-sync port
was attempted, found broken specifically in this app, and reverted
(commit `51504cc`, reverting `8b0d64a`). This file has everything needed to
pick the investigation back up in a fresh thread.

## Symptoms (as reported, verbatim intent preserved)

All observed in **Pesty** (`$HOME/Downloads/pesty-main`, branch
`context-menu-structure`), using the real signed `.app` bundle with the
user's actual settings (custom global hotkey: **⌘⌃V**, not the default):

1. **Pressing the global hotkey to open the bar makes a system "ding" sound.**
   This does *not* happen in the baseline/upstream-bound build (see
   "Comparison build" below).
2. **Return does not paste automatically.** ⌘C (copy) works fine.
3. **Space opens Quick Look successfully** — a preview visibly appears.
4. **Arrow keys work to navigate clips when Quick Look is *not* open.**
5. **Arrow keys do NOT work to navigate between items while Quick Look is
   open** (expected: Left/Right should move between multiple previewed
   items, same as Finder's Quick Look).
6. **Space does NOT dismiss/close Quick Look once it's open** (expected:
   pressing Space again, or clicking away, should close it).

Symptoms 4–6 (Quick Look keyboard interaction) are the ones actively
investigated. Symptoms 1–2 (hotkey ding, Return not pasting) were *reported
in the same session* but not yet confirmed as related — see "Open
questions" below; they may be a separate, pre-existing issue.

## Comparison build (this part already works correctly)

The equivalent feature — Quick Look opened via Space, with working
Left/Right navigation and Space-to-dismiss while it's open — **works
correctly** in the baseline build meant for upstream `momenbasel/pesty`:

- Worktree: `/private/tmp/pesty-pr-quicklook` (may no longer exist if
  cleaned up — branch is `fork/pr-quicklook` in
  `$HOME/Downloads/pesty-main-2`)
- That build's `AppController.swift` and `Util/QuickLookService.swift` are
  a much simpler, from-scratch implementation (this app has no Paste
  Stacks, no Settings-driven inline-preview alternative, etc.), so it's
  not a drop-in comparison — but the *shape* of the fix that worked there is
  below, in case it's a useful starting point.

## What was added, then reverted, in this app

Commit `8b0d64a` ("Dismiss Quick Look with the bar, sync its selection, add
permanent delete") added three things to `Util/QuickLookService.swift` and
`AppController.swift`:

1. `QuickLookService.shared.dismiss()` called from `hideBar()` (in addition
   to the pre-existing call already in `updatePasteStackAvailability()`).
2. A KVO observation on `QLPreviewPanel.currentPreviewItemIndex`, reporting
   back through a new `onSelectionChange: ((UUID) -> Void)?` callback, wired
   in `applicationDidFinishLaunching` to set `store.selectedID`. Intent: when
   Quick Look's own native arrow-key handling moves its selection, the bar's
   highlight should follow.
3. (Unrelated, kept) A "Delete permanently" Settings toggle + Option-key
   delete override — this part is **not reverted** and is believed to work
   fine; it's untangled from the Quick Look work in commit `51504cc`.

An **additional attempted fix**, never committed (also reverted), added to
the top of `handleKey(_:)`:

```swift
if QLPreviewPanel.shared()?.isKeyWindow == true { return event }
```

Intent: once Quick Look genuinely owns the key window, let its own native
Left/Right/Space handling run instead of the bar's local key monitor
processing them first. This is the same pattern already used successfully
elsewhere in this file for the native search field
(`barController?.searchOwnsFirstResponder`) and Pinboard rename
(`fieldEditor.isFieldEditor` check) — checking a concrete, unambiguous piece
of state rather than inferring intent from `event.window`.

**This fix did not resolve the symptom.** See diagnostic evidence below for
why — the assumption behind it (that `QLPreviewPanel` becomes the genuine
key window) doesn't appear to hold in this app.

## Diagnostic evidence gathered

Added temporary logging to the very top of `handleKey(_:)`:

```swift
private func handleKey(_ event: NSEvent) -> NSEvent? {
    FileHandle.standardError.write(Data("[QLDEBUG] handleKey fired. keyCode=\(event.keyCode) QLvisible=\(QuickLookService.shared.isVisible) isKeyWindow=\(QLPreviewPanel.shared()?.isKeyWindow ?? false) event.window=\(String(describing: event.window)) barWindow=\(String(describing: barController?.window)) NSApp.keyWindow=\(String(describing: NSApp.keyWindow))\n".utf8))
    ...
```

**Important lesson learned mid-investigation:** the first two attempts at
capturing this launched `.build/debug/Pesty` directly (an unsigned raw
binary, not inside the `.app` bundle). That does **not** carry the app's
real bundle identity, so `UserDefaults.standard` reads/writes a different
domain than the real app — the custom hotkey, and possibly other settings,
silently don't load. That explained some (but maybe not all — see below) of
the earlier confusion. **Always launch via the actual built `.app`'s
embedded binary directly** to get real settings while still capturing
stdout/stderr, e.g.:

```zsh
cd $HOME/Downloads/pesty-main
VERSION=1.2.0 BUILD=1 ./scripts/build_app.sh
./packaging/Pesty.app/Contents/MacOS/Pesty > /tmp/pesty-debug.log 2>&1 &
```

(`FileHandle.write` was used instead of `print()` specifically because
`print()` output is fully-buffered — not line-buffered — when stdout isn't a
TTY, so it may never appear in a redirected log file until the process exits
cleanly. A `pkill`/SIGTERM does not reliably flush that buffer for a Cocoa
app. `FileHandle.standardError.write` avoids this.)

**With the real signed app running this way**, the user reproduced: opened
the bar, selected a clip, pressed Space (preview visibly opened), pressed
Right arrow twice, pressed Space again. The captured log was:

```
[QLDEBUG] handleKey fired. keyCode=49  QLvisible=false isKeyWindow=false event.window=Optional(<Pesty.BarPanel: 0xc33289180>) barWindow=Optional(<Pesty.BarPanel: 0xc33289180>) NSApp.keyWindow=Optional(<Pesty.BarPanel: 0xc33289180>)
[QLDEBUG] handleKey fired. keyCode=124 QLvisible=false isKeyWindow=false event.window=Optional(<Pesty.BarPanel: 0xc33289180>) barWindow=Optional(<Pesty.BarPanel: 0xc33289180>) NSApp.keyWindow=Optional(<Pesty.BarPanel: 0xc33289180>)
[QLDEBUG] handleKey fired. keyCode=124 QLvisible=false isKeyWindow=false event.window=Optional(<Pesty.BarPanel: 0xc33289180>) barWindow=Optional(<Pesty.BarPanel: 0xc33289180>) NSApp.keyWindow=Optional(<Pesty.BarPanel: 0xc33289180>)
[QLDEBUG] handleKey fired. keyCode=123 QLvisible=false isKeyWindow=false event.window=Optional(<Pesty.BarPanel: 0xc33289180>) barWindow=Optional(<Pesty.BarPanel: 0xc33289180>) NSApp.keyWindow=Optional(<Pesty.BarPanel: 0xc33289180>)
[QLDEBUG] handleKey fired. keyCode=123 QLvisible=false isKeyWindow=false event.window=Optional(<Pesty.BarPanel: 0xc33289180>) barWindow=Optional(<Pesty.BarPanel: 0xc33289180>) NSApp.keyWindow=Optional(<Pesty.BarPanel: 0xc33289180>)
[QLDEBUG] handleKey fired. keyCode=49  QLvisible=false isKeyWindow=false event.window=Optional(<Pesty.BarPanel: 0xc33289180>) barWindow=Optional(<Pesty.BarPanel: 0xc33289180>) NSApp.keyWindow=Optional(<Pesty.BarPanel: 0xc33289180>)
[QLDEBUG] handleKey fired. keyCode=124 QLvisible=false isKeyWindow=false event.window=Optional(<Pesty.BarPanel: 0xc33289180>) barWindow=Optional(<Pesty.BarPanel: 0xc33289180>) NSApp.keyWindow=Optional(<Pesty.BarPanel: 0xc33289180>)
[QLDEBUG] handleKey fired. keyCode=49  QLvisible=false isKeyWindow=false event.window=Optional(<Pesty.BarPanel: 0xc33289180>) barWindow=Optional(<Pesty.BarPanel: 0xc33289180>) NSApp.keyWindow=Optional(<Pesty.BarPanel: 0xc33289180>)
```

(keyCode 49 = Space, 123 = Left, 124 = Right — matches the reported repro
steps.)

**The confusing part:** `QLvisible` (`QLPreviewPanel.shared()?.isVisible`)
reads `false` on *every single logged event*, including immediately after a
Space press that the user confirms visibly opened a preview panel on
screen. `event.window`, `barController?.window`, and `NSApp.keyWindow` are
**all the same `BarPanel` instance** throughout — no `QLPreviewPanel` ever
shows up as the event's window or the app's key window in any logged line,
despite Quick Look being visibly open during at least some of these events.

This is inconsistent on its face: either Quick Look isn't actually the
`QLPreviewPanel.shared()` singleton this code is observing (a different
QL session/instance?), or `isVisible`/`isKeyWindow` don't reflect reality
for some reason specific to this app's window/panel configuration, or the
panel closes and macOS returns key status to the bar faster than expected
between the visible-preview moment and the next logged keystroke.

## Open questions / next steps for a fresh thread

1. **Is `QLPreviewPanel.shared()` actually returning the panel the user is
   seeing?** Consider logging `ObjectIdentifier(panel)` at the moment
   `toggle()` calls `panel.makeKeyAndOrderFront(nil)`, and again in
   `handleKey`, to confirm it's the same instance.
2. **Does `panel.makeKeyAndOrderFront(nil)` actually succeed in this app?**
   This app uses `NSApp.setActivationPolicy(.accessory)`. Worth checking
   whether an accessory app's ability to grant key-window status to a
   secondary panel (especially one hosted via the separate `quicklookd` XPC
   service) has any known quirks. Try logging `NSApp.isActive` and
   `NSRunningApplication.current.isActive` around the toggle.
3. **Are the hotkey "ding" and "Return doesn't paste" symptoms related to
   Quick Look at all, or a separate pre-existing issue?** Worth reproducing
   those two in isolation (never touching Quick Look) to check if they
   happen regardless. If they're unrelated, they deserve their own
   investigation and shouldn't block re-attempting the Quick Look fix.
4. **Try `/usr/bin/log stream --level debug --predicate 'process == "Pesty"'`**
   instead of manual stdout redirection — the established reliable method
   used successfully elsewhere in this project for exactly this kind of
   AppKit-timing bug (see the "Pin context-menu silent failure" fix from
   earlier the same session, which used this method to find that
   `.onAppear` never fires for SwiftUI content in a `.contextMenu`). Console
   unified logging avoids all the buffering/process-identity pitfalls hit
   here.
5. Once the actual state is understood, the fix (if it's what's expected)
   is almost certainly still the `QLPreviewPanel.shared()?.isKeyWindow`
   check at the top of `handleKey` — it just needs the right condition to
   actually detect "Quick Look owns focus right now," which apparently
   isn't `isKeyWindow` in this app's case.

## Reverted code (for reference / re-applying once fixed)

`Util/QuickLookService.swift` diff that was reverted (commit `8b0d64a`,
reverted in `51504cc`):

```swift
    private var indexObservation: NSKeyValueObservation?
    var onSelectionChange: ((UUID) -> Void)?

    // ...in toggle(), after panel.makeKeyAndOrderFront(nil):
    observeIndexChanges(panel)

    private func observeIndexChanges(_ panel: QLPreviewPanel) {
        indexObservation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] _, change in
            guard let index = change.newValue, index >= 0 else { return }
            DispatchQueue.main.async {
                guard let self, let id = self.clipID(forPreviewIndex: index) else { return }
                self.onSelectionChange?(id)
            }
        }
    }

    private func clipID(forPreviewIndex index: Int) -> UUID? {
        orderedStartIndexes.last { $0.index <= index }?.id
    }
```

`AppController.swift`:

```swift
    // in applicationDidFinishLaunching:
    QuickLookService.shared.onSelectionChange = { [weak self] id in
        guard let self, self.store.source != .pasteStack else { return }
        self.store.selectedID = id
    }

    // in hideBar():
    QuickLookService.shared.dismiss()
```
