# Pesty project TODO

Last audited: 2026-08-10 PDT (2026-08-11 UTC for GitHub timestamps); all open PR timelines rechecked, including top-level comments, submitted reviews, and inline threads.

Audited upstream reference: [`momenbasel/pesty` `main` at `bbce746`](https://github.com/momenbasel/pesty/commit/bbce746ca6982a7a2269e6880f97d90f84dbda98)

Local product name: **Pesty**

Purpose: implementation contract and handoff for the next coding agent.

## Release boundary

The roadmap has three distinct release trains. Stage numbers describe technical
dependencies; they do not make later-platform work a prerequisite for an
earlier release.

| Release | Scope | Explicitly excluded |
|---|---|---|
| **2.0.0** | macOS app | Paste Stacks; every iOS target; Mac↔iOS sync |
| **2.1.0** | macOS Paste Stacks, following the upstream tracker | iOS companion, widget, share extension, and Mac↔iOS sync |
| **2.5.0** | iPhone/iPad companion, widget, share extension, and the matching Mac↔iOS private-CloudKit sync | None of this work is back-labelled as 2.0.0 or 2.1.0 |

Run the relevant regression, privacy, signing, and Undo gates separately for
each train. The 2.5.0 companion work may remain in development without blocking
the macOS 2.0.0 release; likewise, Paste Stacks must not be folded into 2.0.0
merely because prototype code exists in the fork.

This is not a request to reopen closed pull requests or merge any current open head as-is. Closed PRs are design/code references. **Every currently open PR remains open and is still required work**; amend/rebase it in place only after its named fixes and foundations are ready. Preserve the Pesty identity isolation throughout.

## How to use this roadmap

1. Read the whole roadmap and the PR ledger before changing code.
2. Use the dependency table as the authority. Normally work in numerical order, but optional/independent stages may be parked indefinitely; never start a dependent stage merely because prototype code already exists locally.
3. Finish one small, testable slice before starting the next. For anything intended for upstream, target roughly **300 changed production lines or fewer** per PR, excluding focused tests and documentation. Split by behavior or layer, not by arbitrary line count.
4. Wait for each dependency to be integrated before building its follow-up. For the personal fork, make the equivalent small checkpoint commits.
5. Treat every old PR as read-only reference material. **Do not reopen, comment on, push to, or otherwise modify any GitHub PR or issue without the fork maintainer's explicit approval.**
6. Re-check upstream `main` at the start of implementation. `bbce746` is the audit reference, not permission to ignore newer upstream work.
7. A checked item means it was verified in this checkout during the audit. It does not mean it has been committed or pushed.

## Live open-PR disposition proposal

Rechecked 2026-08-10 PDT / 2026-08-11 UTC, including every top-level comment, submitted review, and inline review thread on the 15 open PRs. No formal submitted reviews or inline review threads exist on these PRs; each has one decisive top-level maintainer comment, while #41 also has earlier duplicate author screenshot comments. Every head is 13 commits behind audited `main` at `bbce746`; historical green CI does not prove current-main compatibility. None of the open branches literally contains a rejected prerequisite PR, so **no PR should be closed merely because a dependency was rejected**.

No current head is ready to merge as-is. This is a proposal only: no PR should be closed, edited, commented on, or otherwise changed on GitHub without the fork maintainer's explicit approval.

| Open PR | Proposed disposition | Maintainer outcome and required revision |
|---:|---|---|
| [#14](https://github.com/momenbasel/pesty/pull/14) | **Keep/Revise; blocked; last** | [Liquid Glass is wanted](https://github.com/momenbasel/pesty/pull/14#issuecomment-5247447945), but Xcode 26.3 must be selected in CI/release, #63/#64 preserved, bottom notches/double tint/duplicate shadow fixed, and macOS 14/26 QA recorded. |
| [#15](https://github.com/momenbasel/pesty/pull/15) | **Keep/Revise; blocked on #41** | [Card-body direction is liked](https://github.com/momenbasel/pesty/pull/15#issuecomment-5247494659), but shared black text makes Dark Mode chrome unreadable. Split `chromeText*`/`cardText*`, improve the inner stroke, remove `.scrollClipDisabled()`, and rebase after #41. |
| [#16](https://github.com/momenbasel/pesty/pull/16) | **Keep/Revise; blocked on tests** | [Drag-out is wanted](https://github.com/momenbasel/pesty/pull/16#issuecomment-5247489680); the 80 ms hide timer is rejected. Use safe drag-session lifecycle, all files, `public.url`, native color, lazy images, collision-safe names, and cancellation/reopen tests. |
| [#17](https://github.com/momenbasel/pesty/pull/17) | **Keep/Revise; blocked** | [The read path is explicitly wanted](https://github.com/momenbasel/pesty/pull/17#issuecomment-5247499190). Preserve actual origin, validate the marker, resolve ID/name together, and apply #27 exclusions; keep #61's `CopyResult`/toast as a separate slice. |
| [#18](https://github.com/momenbasel/pesty/pull/18) | **Keep/Revise; blocked on trigger rewrite/tests; early candidate** | [The bug is confirmed](https://github.com/momenbasel/pesty/pull/18#issuecomment-5247495036), but `selectedID` usually does not change. Use a presentation token/scroll state, preserve the leading inset, and test same-ID/rapid reopen. |
| [#19](https://github.com/momenbasel/pesty/pull/19) | **Keep/Revise; blocked on repeat-safe exact deletion** | [Bare Backspace is wanted](https://github.com/momenbasel/pesty/pull/19#issuecomment-5247448060), but repeat events and current cross-container selection/deletion are unsafe. The maintainer's minimum unblock is repeat suppression; exact scope, adjacent selection, docs/tests also remain. Pesty additionally defers final release until Stage 16 Undo. |
| [#20](https://github.com/momenbasel/pesty/pull/20) | **Keep/Revise; blocked on #42 infrastructure** | [The idea is right](https://github.com/momenbasel/pesty/pull/20#issuecomment-5247494782), but character parsing breaks the default chord. Use key codes for 1–9, prevent modifier conflicts, define file/plain-text behavior, and test non-US layouts. |
| [#21](https://github.com/momenbasel/pesty/pull/21) | **Keep/Revise; blocked on retention/sync redesign** | [Current implementation is unsafe](https://github.com/momenbasel/pesty/pull/21#issuecomment-5247449956): it breaks current `trimHistory()`/CloudKit compilation and can turn one device's policy into account-wide deletion. Keep the PR open, preserve its useful preference migration, and rewrite the retention engine after choosing safe sync semantics. |
| [#22](https://github.com/momenbasel/pesty/pull/22) | **Keep open; blocked on #42 `pasteTarget`** | [The isolated guard/default are correct](https://github.com/momenbasel/pesty/pull/22#issuecomment-5247494930), but persistence exposes stale destination, escape, modal-level, full-screen, and Cmd-Tab/Settings semantics. Rebase/update after target resolution. |
| [#36](https://github.com/momenbasel/pesty/pull/36) | **Keep/Revise; documentation-only** | [Maintainer supplied mergeable wording](https://github.com/momenbasel/pesty/pull/36#issuecomment-5247499565): visual changes require before/after strip images; only a stated no-visual-delta change may omit them. |
| [#37](https://github.com/momenbasel/pesty/pull/37) | **Keep/Revise** | [Head truncation is good](https://github.com/momenbasel/pesty/pull/37#issuecomment-5247499441), but the binary `22→700 pt` jump is not. Use content-driven ideal width capped at `700 pt`; remove the no-op reserve/GeometryReader/container label. |
| [#38](https://github.com/momenbasel/pesty/pull/38) | **Keep/Revise; blocked on launch-source redesign** | [Reopen behavior is wanted](https://github.com/momenbasel/pesty/pull/38#issuecomment-5247489562); unconditional delayed presentation after every launch is rejected because it breaks Launch at Login. Keep the PR open: preserve first-run onboarding, safely show for explicit user launches/reopens, and never show for login/background launch. The user-launch addition is a Pesty requirement that needs redesign and upstream re-discussion. |
| [#40](https://github.com/momenbasel/pesty/pull/40) | **Keep/Revise; blocked on deletion/selection redesign** | [Collection-scoped deletion/image cleanup is wanted](https://github.com/momenbasel/pesty/pull/40#issuecomment-5247489406) and lands first; multi-select also remains required, but needs event-carried modifiers, reconciliation, confirmation, current identity semantics, and Undo integration. |
| [#41](https://github.com/momenbasel/pesty/pull/41) | **Keep/Revise** | [Padding is wanted](https://github.com/momenbasel/pesty/pull/41#issuecomment-5247499323); alignment/GeometryReader is a measured no-op. Keep only top `4→16 pt` and bottom `18→26 pt`, test at `300 pt`, and rename around spacing. |
| [#42](https://github.com/momenbasel/pesty/pull/42) | **Keep/Revise; blocked on foundations and safe mutation model** | [Key-monitor scoping and `pasteTarget` land first](https://github.com/momenbasel/pesty/pull/42#issuecomment-5247489252). The menu/editor/context feature remains required, but the current 921-line head must be rebuilt around CloudKit-safe mutation, current IDs, native menus, explicit clipboard behavior, and correct lifecycle. |

**Proposed upstream slice order:** independent documentation amendment #36; Stage 1/#50 test-target extraction; #42 key-monitor foundation; #42 `pasteTarget` foundation; minimal native App/Edit/Window menu; revised #38 launch/reopen behavior; revised #18, #20, #37, and #22 as their Stage 2 dependencies permit; revised #41; revised #17; #40 exact-deletion foundation; revised #15 and #16; complete #21 retention, #40 multi-select, and #42 editor/context after their foundations; #14 last among the visual/open feature PRs after the toolchain decision; then the final Stage 16 five-minute Undo release gate and revised #19 integration. The dependency table below is authoritative if this suggested priority order conflicts with an implementation prerequisite.

## Critical repository warning

The current checkout is not a normal continuation of upstream `main`:

- The current local branch is `context-menu-structure` at `f4a07eb`.
- Git reports **no merge base** between this branch and audited upstream `main`.
- The working tree contains a large mixture of tracked modifications, deletions, and untracked files, including the completed Pesty identity work.
- The local tree currently omits upstream CloudKit source files and contains an older Paste Bar window controller that regresses merged fixes [#63](https://github.com/momenbasel/pesty/pull/63) and [issue #64](https://github.com/momenbasel/pesty/issues/64).

Therefore:

- [ ] Before implementation, show the fork maintainer the exact dirty-tree inventory and agree on a recoverable checkpoint.
- [ ] Do **not** run a destructive reset, checkout, clean, ordinary rebase, or bulk conflict resolution.
- [ ] Prefer creating a clean integration branch from the then-current upstream `main`, then porting the Pesty identity changes and approved feature slices deliberately.
- [ ] If work continues in this checkout instead, restore current-main architecture file by file and prove equivalence with tests before feature work.
- [ ] Include every identity-critical untracked file in any checkpoint, especially `Sources/Pesty/AppIdentity.swift`, the renamed entitlement files, and the entire intended `iOSApp/` tree.

### Local prototype inventory — present does not mean complete

The checkout already contains prototype implementations for live resize, a Settings sidebar, Pinboard reorder/swatches/inline rename, clip editing/context actions, previews/link metadata/external open, Paste Stacks, drag providers, copy toast, Liquid Glass, launch/reopen, search expansion, multi-select, and configurable modifiers. Reuse can save time, but each must enter through its roadmap stage and acceptance tests.

Known reasons the local prototypes cannot be treated as finished:

- The macOS package has no test target.
- The local bar controller uses older visibility/animation flags and can regress #63/#64.
- Current-main CloudKit/sync files are deleted in the local comparison.
- Local update/delete helpers still contain shared-UUID assumptions that conflict with per-container copies.
- `pasteStacksFollowHistory` currently defaults to false, retaining stack payloads after Clear History.
- Outgoing copy marks Pesty as source instead of preserving every clip's actual origin; incoming declared source is not bounded/validated.
- Drag-out eagerly handles some images on the MainActor, exposes only one file, and lacks correct native URL/color representations and drag-end lifecycle.
- Preview/network/temp cleanup and Paste Stack identity/sync behavior have not passed the privacy gates below.
- The local source-color prototype does not yet expose the approved Default/Vibrant/Accent Shades contract.
- The generated/renamed iOS project builds, but physical-device provisioning and live CloudKit sync are not proven.

## Non-negotiable product and architecture rules

### Pesty identity and coexistence

- [x] macOS visible product, app bundle, executable, icon, and System Settings-facing name are `Pesty`.
- [x] macOS bundle and signing identifier are `com.alvst.pesty`.
- [x] iOS visible product is `Pesty`; app and test IDs are `com.alvst.pesty.companion` and `com.alvst.pesty.companion.tests`.
- [x] Pesty's CloudKit container reference is `iCloud.com.alvst.pesty`.
- [x] Local storage uses `Application Support/Pesty`; iCloud Drive storage uses `Pesty`; temporary exports use Pesty-specific directories.
- [x] User defaults, login item registration, Accessibility/TCC identity, app bundle, and designated requirement are isolated from upstream Pesty.
- [x] The default global shortcuts are distinct from upstream Pesty, and the Carbon signature is `ALVI`.
- [ ] Preserve those values in every build script, entitlement, generated Xcode project, release artifact, help page, About screen, user agent, and fallback identifier.
- [ ] Keep the Swift module/target and internal model names such as `Pesty`, `PestyMain`, `PestyClip`, and `PestyBoard` where changing them would be needless source/schema churn.
- [ ] Keep standard pasteboard types such as `org.nspasteboard.source` unchanged. Preserve the clip's validated actual origin in the marker; use Pesty's bundle ID only when the item has no valid source ID.
- [ ] Never add automatic fallback reads or writes to upstream Pesty's defaults or storage directories. A one-time user-approved copy while both apps are quit is the only acceptable data migration.
- [ ] Assume the system pasteboard is intentionally shared. Coexistence does not mean separate clipboards.

Exact identity map to preserve:

| Upstream identity/artifact | Pesty identity/artifact |
|---|---|
| `Pesty.app` / executable `Pesty` | `Pesty.app` / executable `Pesty` |
| `Pesty.icns`, `Pesty.iconset` | `Pesty.icns`, `Pesty.iconset` |
| `Pesty.entitlements`, `Pesty-MAS.entitlements` | `Pesty.entitlements`, `Pesty-MAS.entitlements` |
| `com.greycorelabs.pesty` | `com.alvst.pesty` |
| `Application Support/Pesty` | `Application Support/Pesty` |
| iCloud Drive folder `Pesty` | iCloud Drive folder `Pesty` |
| temp `Pesty-QuickLook`, `Pesty-Open` | `Pesty-QuickLook`, `Pesty-Open` |
| iOS `com.greycorelabs.pesty.companion` | `com.alvst.pesty.companion` |
| iOS test bundle | `com.alvst.pesty.companion.tests` |
| `iCloud.com.greycorelabs.pesty` | `iCloud.com.alvst.pesty` |
| iOS local directory `PestyCompanion` | Pesty-specific local directory `Pesty` |
| Carbon signature `PSTY` | `ALVI` |
| upstream default global hotkeys | Pesty defaults `⌃⌘V` and `⌃⌥⌘V` |

Keep the package product named `Pesty`, but keep the internal Swift target/module at `Pesty`. Point About/support links only to a real fork URL such as `https://github.com/alvst/pesty`, or label links explicitly as upstream; do not invent a repository URL.

### Current-main behavior that must not regress

- [ ] Preserve merged [#63](https://github.com/momenbasel/pesty/pull/63): target-screen selection, bar-height clamping, a panel that stays in its final display frame, and animation of content inside a clipped panel.
- [ ] Preserve completed [issue #64](https://github.com/momenbasel/pesty/issues/64): authoritative `hidden/showing/shown/hiding` phase, epoch tokens, completion backstop, `forceHide()` on wake/display changes, missing-panel recovery, and failed-hotkey retry.
- [ ] Never restore `window.isVisible` as lifecycle authority, `isPresenting`/`isHiding` booleans, whole-window animation below a screen, `NSScreen.main` as the normal target, or uncancellable delayed hide completions.
- [ ] Treat current-main's per-container UUID behavior as authoritative. History, pinboard, and future Paste Stack copies must not silently share one `ClipItem.id`.
- [ ] Keep the macOS and iOS copies of `CloudKitSchema.swift` byte-identical whenever sync code is present.
- [ ] Do not change existing CloudKit field types or meanings. Additive schema work requires migration, compatibility, and two-device tests.
- [ ] Direct builds may use Accessibility-assisted paste. MAS builds must remain free of forbidden Accessibility/CGEvent paths and use copy plus app reactivation.

### Privacy, safety, and data ownership

- [ ] No background URL fetching by default. Link metadata/network previews must be explicit, default-off, bounded, and reflected in privacy disclosures.
- [ ] Owner-only temporary directories and files: directories `0700`, exported payload files `0600`, unique names, bounded lifetime, startup cleanup.
- [ ] Validate all external pasteboard data before persistence, LaunchServices lookup, exclusion checks, file access, or network use.
- [ ] A destructive action must identify the exact container record and prove whether an image/payload file is still referenced before deleting it.
- [ ] `Clear History` must do what its wording promises. By default, linked Paste Stack payloads and images must also be removed.
- [ ] Paused capture, excluded apps, concealed/transient pasteboard types, and remote ingest must not bypass privacy filters.

## Design baseline and sizing contract

These values describe the current Pesty prototype and the intended visual proportions. They are starting constraints, not permission to clip content on a small display. Every visual change must include before/after screenshots of the full strip and test the smallest supported visible frame. If a change has no visual delta—such as a refactor, accessibility-label change, or focus-order fix—say so explicitly in the PR/checkpoint description instead.

| Surface/token | Baseline | Required behavior |
|---|---:|---|
| Paste Bar height | default `430 pt`; setting `300...720` in `10 pt` steps | Clamp to the target display's visible height; keep the panel bottom-aligned; resize content and panel together without breaking #63/#64. |
| Card width | `215 pt` | Keep cards scannable and stable while navigating. Do not resize individual cards according to content. |
| Visible card gap | `28 pt` | Selected ring and shadow must never collide with adjacent cards. |
| Strip viewport inset | `20 pt` | The selected ring must remain fully visible at both viewport edges. |
| Strip edge buffer | `29 pt` plus scroll-target padding | First/last cards must not sit flush to the clip boundary. |
| Strip vertical insets | `16 pt` top, `26 pt` bottom | Port only the accepted two padding changes from [#41](https://github.com/momenbasel/pesty/pull/41). Do not port its GeometryReader, explicit card-height arithmetic, or redundant stack alignment. Verify usability at the `300 pt` minimum and account for the resize handle. |
| Panel/card corners | `16 pt` / `19 pt` | The card shape should read separately from the selected focus ring. |
| Card header | `68 pt` | Source icon, title, app, and relative time must remain legible without crowding. |
| Selected-card ring | vivid system blue, `6 pt` | Primary keyboard target must be unmistakable against bright and saturated source colors. Color alone is not sufficient for multi-select. |
| Resize affordance | visible line `42 x 4 pt` inside at least a `42 x 14 pt` hit region | Cursor and accessibility description must communicate vertical resizing; dragging must remain easy at 1x and 2x scale. |
| Search field | collapsed near `22 pt`; content-driven growth up to a `700 pt` cap while filtering | Preserve `.truncationMode(.head)` so newest characters remain visible. Do not use the rejected binary GeometryReader width, ineffective chrome reserve, or a container accessibility label that masks **Clear search**. Compress safely around trailing controls on narrow displays. See [#37](https://github.com/momenbasel/pesty/pull/37). |
| Settings window | `760 x 680 pt` | Keep native resizability/keyboard navigation; no pane should be clipped at the default size. |
| Settings sidebar/content | sidebar about `174 pt`; content max `548 pt` with `24 pt` padding | Preserve General, Privacy, Shortcuts, Sync, and About; show the correct MAS/non-MAS sync UI. |
| Detached inline preview | starts around `500 x 340 pt`; clamps to `360...540 x 260...420 pt` | Keep `20 pt` from the screen edge, pointer at least `34 pt` from preview corners, panel non-key, and selected card visible. |
| Compact preview body | about `340 pt` wide; media thumbnail about `104 pt` tall | Text and actions must not truncate at normal localization lengths. |
| Paste Stack tray | about `318 x 420 pt` | Keep at least `22 pt` from screen edges and about `14 pt` above the bar; adapt if that would leave insufficient space. |
| Clip editor | starts `760 x 560 pt`; minimum `520 x 380 pt`; editor area at least `260 pt` high | Resizable, standard text editing, no fixed frame that clips error/action rows. |
| Copy toast | about `236 x 48 pt`; show/hide near `0.16/0.18 s` | Non-key, one concise line, no destination focus loss, and never shown for a failed copy. |
| Delete Undo control | native trailing button, at least `28 pt` high with about `10 pt` horizontal padding | Appears only while a deletion batch is undoable, stays at the right side of the Paste Bar toolbar, never overlaps search/actions, and disappears at the five-minute deadline. |

### General visual rules

- Use native macOS typography, controls, focus behavior, menus, and accessibility semantics.
- Prefer one clear primary action per transient surface. Keep destructive actions visually separated and confirm destructive multi-item work.
- Keep source color in the header, a light readable body, strong text contrast, and a visible keyboard-selection outline.
- Do not make a non-key preview or toast steal key/main status from the destination app or Paste Bar.
- Every drag-only reorder needs Move Left/Right or Move Up/Down commands and VoiceOver support.
- Test long app names, custom clip titles, localized text, missing icons, reduced motion, increased contrast, and VoiceOver.

---

# Implementation stages

| Stage | Deliverable | Main dependencies |
|---:|---|---|
| 0 | Recoverable Pesty baseline on current architecture | User-approved preservation decision |
| 1 | Test target and required CI | Stage 0 |
| 2 | Responder chain, menus, target resolution, lifecycle, modifiers, and corrected search pill | Stages 0–1 |
| 3 | Resize handle, accepted strip spacing, and stable Settings sidebar | Stage 2 and #63/#64 restoration |
| 4 | Source themes and Pinboard organization | Stages 1–3 |
| 5 | Validated provenance, CopyResult, and toast | Stages 1–2 |
| 6 | Exact collection deletion first; revised retention design second | Stages 1 and 5 |
| 7 | Mutation engine, editor, and context menu | Stages 2, 5–6 |
| 8 | Multi-select and bulk delete | Stages 2 and 6–7 |
| 9 | Safe drag-out | Stages 2, 5–6 |
| 10 | Local Quick Look, detached preview, external open | Stages 2, 5–7 |
| 11 | Default-off link enrichment | Stage 10 plus privacy review |
| 12 | Paste Stack identity/persistence/privacy engine (2.1.0) | Stages 1–2, 5–6 |
| 13 | Paste Stack capture/paste/UI (2.1.0) | Stage 12, plus Stages 7–10 as used |
| 14 | Liquid Glass and final visual polish | #41 spacing in Stage 3 → #15 palette/card update → #14 last after pinned Xcode 26.3; preserve #63/#64; Stack-specific polish waits for Stage 13 |
| 15 | 2.5.0 iOS companion, extensions, Mac↔iOS sync, and packaging | Mac sync/schema behavior included in 2.5.0; earlier trains do not depend on this stage |
| 16 | Five-minute deletion Undo and per-train release gates | Stages 5–8 plus only the feature stages included in that release |

## Stage 0 — Preserve the fork and restore a trustworthy baseline

**Goal:** make the Pesty work recoverable, then remove architectural regressions before adding features.

**References:** merged [#3](https://github.com/momenbasel/pesty/pull/3), [#7](https://github.com/momenbasel/pesty/pull/7), [#23](https://github.com/momenbasel/pesty/pull/23), [#25](https://github.com/momenbasel/pesty/pull/25), [#27](https://github.com/momenbasel/pesty/pull/27), [#39](https://github.com/momenbasel/pesty/pull/39), [#63](https://github.com/momenbasel/pesty/pull/63), and completed [issue #64](https://github.com/momenbasel/pesty/issues/64).

- [ ] Make a user-approved checkpoint containing all intended tracked and untracked Pesty files. Record the pre-checkpoint `git status` and exact HEAD.
- [ ] Reconfirm whether a clean current-main integration branch or in-place restoration is the chosen path. Do not assume.
- [ ] Restore/adapt current-main CloudKit and sync files that the local tree currently deletes.
- [ ] Port the Pesty identity through restored files without reintroducing `com.greycorelabs.pesty`, upstream Team IDs, storage paths, or artifact names.
- [ ] Restore #63/#64's `BarWindowController`, AppController integration, and hotkey retry behavior before porting any feature code that touches those files.
- [ ] Force-disable unfinished Paste Stack capture, UI, and shortcut registration at baseline. Preserve existing local prototype data for the explicit Stage 12 migration, but prevent unsafe Stack persistence from shipping; do not attempt a partial setting flip before the tested identity/asset engine exists.
- [ ] While restoring current sync sources, correct the stale `CloudSyncService.desiredRecords` comment that says a pinned clip keeps its UUID. Pinboard copies mint independent IDs, and CloudKit record names are globally keyed by those independent copy IDs—not by reusing one ID in multiple containers.
- [ ] Verify the current local Pesty build contains no upstream bundle/team ID or upstream storage/temp path in its compiled executable.
- [ ] Verify the old ignored upstream `Pesty.app`, icons, and `.build/.../Pesty` products are not recreated or accidentally distributed. A temporary backup is not a release artifact.
- [ ] Keep the fork's standard shortcuts distinct from upstream so both apps can be installed; document that only one app can own an identical global shortcut.

**Exit gate**

- [ ] Direct macOS build succeeds as a universal app and reports `Pesty`, `com.alvst.pesty`, and the matching designated requirement.
- [ ] MAS compile path succeeds without using upstream certificates, profiles, Team IDs, or signing defaults.
- [ ] iOS simulator build-for-testing succeeds with the renamed product, app/test IDs, module import, test host, and CloudKit entitlement.
- [ ] The three existing iOS tests pass.
- [ ] Manual co-install check shows separate Login Items and Accessibility entries and separate empty storage/defaults.
- [ ] Rapid show/hide/reopen and mixed/stacked-display placement match current #63/#64 behavior.

## Stage 1 — Test target and CI safety net

**Goal:** land the infrastructure the maintainer explicitly requested first.

**PR lineage:** closed [#50](https://github.com/momenbasel/pesty/pull/50) contained a useful small test-target commit but was stacked on missing Paste Stack work. Re-cut only the infrastructure on current main; do not reopen #50.

- [ ] Add a standalone SwiftPM `PestyTests` target without importing Paste Stack production code merely to make old tests compile.
- [ ] Add one small current-main unit test in the same slice to prove discovery and linking.
- [ ] Introduce dependency seams for temporary storage/defaults where tests need them; tests must never touch a user's live pasteboard history, defaults, iCloud, Application Support, or images.
- [ ] Add CI for `swift test`, `swift build`, `swift build -Xswiftc -DMAS`, and `git diff --check`.
- [ ] Add the universal local app build as a release-readiness gate without requiring the fork maintainer's personal signing secrets on ordinary PRs.
- [ ] Keep Swift 6 strict-concurrency diagnostics clean and do not hide warnings by weakening compiler settings.
- [ ] Make failures block dependent work. Do not postpone all tests until the final feature PR.

**Exit gate**

- [ ] All four commands pass from a clean checkout.
- [ ] A deliberately failing test is observed to fail CI before being reverted.
- [ ] Test output proves paths/default suites are isolated.
- [ ] Production behavior and packaged identity are unchanged.

## Stage 2 — Responder chain, keyboard, paste target, and lifecycle foundation

**Goal:** make menus, text fields, navigation, paste handoff, and reopening reliable before adding editors or complex menus.

**PR lineage:** keep/revise open [#42](https://github.com/momenbasel/pesty/pull/42), landing its key-monitor and `pasteTarget` foundations before rebuilding its full editor/context behavior; its current 921-line head is blocked, not abandoned. Use the intent of closed [#4](https://github.com/momenbasel/pesty/pull/4), reliability slices from closed [#49](https://github.com/momenbasel/pesty/pull/49), the narrowly invited race fix from closed [#24](https://github.com/momenbasel/pesty/pull/24), open [#18](https://github.com/momenbasel/pesty/pull/18), open [#20](https://github.com/momenbasel/pesty/pull/20), and blocked-open [#22](https://github.com/momenbasel/pesty/pull/22). Keep/revise open [#38](https://github.com/momenbasel/pesty/pull/38): preserve onboarding, implement the accepted reopen behavior, and redesign its normal-launch presentation so only an explicit user launch—not Launch at Login/background startup—may show the bar. Closed [#60](https://github.com/momenbasel/pesty/pull/60) confirms the reopen boundary; the additional foreground-launch behavior requires upstream re-discussion.

**Upstream landing order within this foundation:** #42 key-monitor foundation → #42 `pasteTarget` foundation → minimal native App/Edit/Window menu → revised #38 launch/reopen behavior → revised #18/#20/#22 behavior as their dependencies permit → revised #37 content-driven search. #36 is independent documentation work; #41 spacing belongs in Stage 3.

### 2A — Key monitor and native menus

- [ ] Make `guard event.window === barController?.window else { return event }` or the current-main equivalent the first check in the local `handleKey` path, before bar command dispatch.
- [ ] Suspend/gate bar shortcuts whenever a field editor, rename field, alert, Settings control, editor, or native menu owns the event.
- [ ] Extract this monitor scoping from #42 as its own small current-main slice. Do not carry the editor, context menu, preview, or mutation code with it.
- [ ] Add a minimal native App/Edit/Window menu so Undo, Redo, Cut, Copy, Paste, Select All, Find, Close, and Quit behave normally.
- [ ] Confirm accessory/`LSUIElement` behavior and the status menu remain intact.
- [ ] Do not consume Space or ordinary typing when an existing text field, field editor, menu, or alert owns first responder. Quick Look-specific Space behavior is deferred to Stage 10.

### 2B — Current destination and paste handoff

- [ ] Resolve the current non-Pesty destination at action time. Do not keep an app captured at launch, stack creation, or a stale menu opening as the permanent paste target.
- [ ] Extract `pasteTarget` from #42 as a second independent slice after key-monitor scoping. #42—not #49—is the source of truth for target resolution.
- [ ] Scope event/key monitors to Pesty's own surfaces and remove them cleanly.
- [ ] For direct builds: capture the destination PID at action time, hide synchronously through #64's phase model, wait for the physical shortcut/Return modifiers to lift, then post Cmd-V directly to that PID. Cooperative app activation is only a tested fallback for unusual reopen/menu-bar paths, not the normal sequence.
- [ ] For MAS builds: copy, return focus to the destination, and do not compile forbidden direct-paste APIs.
- [ ] Invalid or unwritable payloads must never trigger a stale paste into another app.
- [ ] Port stable visible-card scrolling and reliable handoff residue from #49 as separate slices; use #42 as the source of truth for `pasteTarget`, and do not copy #49's old window controller. Copy promotion belongs in Stage 5 after `CopyResult`.
- [ ] Landing gate: integrate and test the #42 key-monitor and `pasteTarget` slices before updating #20 or #22. Those focused open PRs do not depend on a rejected branch; #49 remains read-only behavioral reference.

### 2C — Show/hide/reopen behavior

- [ ] Fix the narrowly identified #24 race: `show()` must cancel/obsolete an in-flight hide animation so a completion from the previous epoch cannot close a newly shown bar.
- [ ] Reset the clip strip on every presentation, per #18, using a monotonically changing `barPresentationToken` or macOS-14-compatible `scrollPosition(id:)` state. Do not key the reset to `selectedID`, which may remain the same and can leave a stale flag that hijacks the next real selection.
- [ ] Preserve the strip's `18 pt` leading inset during that reset; do not scroll the inset itself out of view. Cover trackpad-scroll→hide→same-ID reopen, empty history, repeated opens, and rapid #64 presentations.
- [ ] Modify current main's one existing `applicationShouldHandleReopen`; do not add a second handler. Preserve hidden-menu-icon recovery.
- [ ] First run must retain onboarding Settings and its Accessibility explanation. Launch at Login and non-user background launches must **not** auto-present the bar or steal focus.
- [ ] Define an explicit, testable launch intent—first run, foreground user launch, user reopen, or login/background launch. Do not infer intent from a fixed delay.
- [ ] A foreground user launch or Dock/Finder/Spotlight reopen may show the Paste Bar on the pointer's display. Gate on `barController.isPresented`, never `window.isVisible`; coalesce duplicate requests and never reset an already-active session.
- [ ] Launch at Login/background launch must remain hidden with no focus flash. If macOS does not provide a trustworthy source signal in the chosen architecture, prefer hidden state and require an explicit user action rather than guessing.
- [ ] Revise #38 in place with this launch-source-aware behavior. The upstream comment explicitly accepts reopen and rejects unconditional launch presentation; therefore present foreground-launch behavior as a Pesty requirement needing maintainer approval, not as already accepted review feedback.
- [ ] Keep #22 blocked until the #42 `pasteTarget` slice lands. Its default and three-line guard are correct in isolation, but a persistent bar must update the destination whenever another non-Pesty app activates so Safari→Notes cannot still paste into Safari.
- [ ] For #22, provide a reliable hide/escape route even while the bar is non-key and the menu icon is hidden; decide a non-obstructive panel level for persistent mode/full-screen apps; align the setting label with the real `windowDidResignKey`/Cmd-Tab/Settings triggers; preserve `suppressAutoHide` and #64 epochs.

### 2D — Configurable quick-paste modifiers

- [ ] Match shortcuts using `keyCode` plus normalized modifiers, not localized characters or `charactersIgnoringModifiers`.
- [ ] Match digits explicitly with `kVK_ANSI_1...9`, including Shift/non-US-layout cases; never parse `"!"` or other localized punctuation back into a digit.
- [ ] Reject unsupported combinations and conflicts with the main hotkey, Paste Stack hotkey, menu shortcuts, and system-reserved combinations.
- [ ] Prevent or explicitly resolve identical quick-paste and plain-text modifier selections. Define file plain-text behavior so it does not silently paste bare filenames, and either expose the plain-text path through intended non-digit commands or narrow/document the feature honestly.
- [ ] Persist normalized `NSEvent.ModifierFlags.rawValue` rather than a second ad-hoc modifier encoding.
- [ ] Preserve existing Pesty defaults through migration; a reset must restore the fork's non-conflicting defaults, not upstream's.

### 2E — Content-driven search pill

- [ ] Revise #37 in place after responder-chain foundations.
- [ ] Preserve `.truncationMode(.head)` so the newest typed characters remain visible.
- [ ] Remove the binary `GeometryReader`, `searchWidth`, and ineffective minimum-chrome-reserve approach.
- [ ] Let the text retain its ideal width and cap the container from about `22 pt` through `700 pt`; one character must create a small pill rather than a 700-point jump.
- [ ] Keep **Clear search** accessibility on the button itself; remove a container label that could mask that action.
- [ ] Compress around trailing controls at narrow widths and preserve current-main MAS/non-MAS sync-button gating while resolving the stale branch.

**Exit gate**

- [ ] Typing, Space, Backspace, Delete, arrows, Return, Escape, and standard editing shortcuts behave correctly in current search/Settings fields, a responder-chain test field, menus, and alerts. Later rename/editor stages repeat these assertions for their new controls.
- [ ] Direct and MAS paste flows target the correct app after menu use, app switching, modifier hold/release, target termination, and Accessibility denial.
- [ ] Quick-paste tests cover 1–9, every allowed modifier, the default combined chord, conflicting pickers, non-US layouts, rich text, and file clips.
- [ ] With #22 persistence enabled, Safari→open bar→Notes targets Notes; Settings, Cmd-Tab, full-screen Spaces, a hidden menu icon, global-hotkey dismissal, MAS copy/reactivation, and direct paste retain both the correct destination and a usable hide path.
- [ ] Trackpad-scroll away from the first card, hide, and reopen with the same selected UUID: the first clip and full leading inset are restored without a stale reset flag; the next real selection still centers normally.
- [ ] Search grows continuously with content, retains newest text, preserves the clear button's accessibility action, and never overlaps controls at the minimum supported width.
- [ ] Ten rapid hide/show/reopen cycles do not strand or close the bar.
- [ ] Pointer-display selection passes on horizontally arranged, vertically stacked, portrait, gapped, and mixed-scale displays.
- [ ] Launch at Login causes no focus flash.

## Stage 3 — Resize, accepted strip spacing, and Settings information architecture

**Goal:** establish safe live bar sizing, the accepted strip breathing room, and the permanent settings/navigation surface.

**PR lineage:** closed [#5](https://github.com/momenbasel/pesty/pull/5) was closed for staleness, not merit; the maintainer explicitly welcomed a current-main re-cut. Closed [#6](https://github.com/momenbasel/pesty/pull/6) was also welcomed if it preserves the current MAS CloudKit UI. Keep/revise open [#41](https://github.com/momenbasel/pesty/pull/41): the maintainer wants only its two padding changes and measured its alignment commit as a no-op. Closed [#32](https://github.com/momenbasel/pesty/pull/32) is too large and should be split by pane or parked. Closed [#35](https://github.com/momenbasel/pesty/pull/35) is a tiny selected-position preference but should be implemented only after navigation semantics are settled.

### 3A — Live resize handle

- [ ] Rebuild the #5 handle on top of #63/#64, using screen coordinates and the current target display.
- [ ] Begin dragging without a jump, update panel and content together, remain bottom-aligned, and clamp to both `300...720 pt` and the display's usable height.
- [ ] Persist only a finite, clamped final height. A cancelled/failed drag must leave a valid value.
- [ ] Keep the visible `42 x 4 pt` affordance in an accessible hit region of at least `42 x 14 pt`; set the resize cursor and VoiceOver help.
- [ ] Reduced Motion may remove interpolation, but must not break drag tracking or final placement.

### 3B — Settings sidebar

- [ ] Re-cut #6 with General, Privacy, Shortcuts, Sync, and About destinations.
- [ ] Preserve every control implemented through Stage 3 while moving it. Reserve coherent destinations for later retention, preview-privacy, and Paste Stack controls, but do not ship nonfunctional placeholders.
- [ ] Preserve the complete `#if MAS` CloudKit status/toggle and non-MAS iCloud Drive UI.
- [ ] At `760 x 680 pt`, no pane may clip controls or require horizontal scrolling. Sidebar stays about `174 pt`; content stays readable up to about `548 pt` plus padding.
- [ ] Use native sidebar selection, full keyboard navigation, correct toolbar/title behavior, and stable window restoration.
- [ ] Split any broader #32 polish by pane and keep each slice independently useful.

### 3C — Accepted strip spacing

- [ ] Drop #41's alignment/GeometryReader commit entirely.
- [ ] Change only strip top padding `4→16 pt` and bottom padding `18→26 pt`.
- [ ] Do not introduce explicit card-height arithmetic, `max(1, …)` first-layout behavior, or redundant `LazyHStack(alignment: .top)`.
- [ ] Rename the upstream PR around spacing rather than alignment.
- [ ] Capture before/after full-strip evidence at default height and the `300 pt` minimum; verify usable card height, selected ring, bottom edge, and resize affordance.

### 3D — Optional selection-position preference

- [ ] After keyboard/scroll semantics are stable, decide whether #35's selected-card position is still wanted.
- [ ] If implemented, expose clear choices such as leading/centered and define first/last-card behavior. It must not cause oscillating scroll corrections or hide focus rings.

**Exit gate**

- [ ] Resize is visually and numerically correct on every display arrangement in the manual matrix.
- [ ] All Settings controls and help text exist in both MAS and direct builds.
- [ ] Tab/Shift-Tab, arrow navigation, VoiceOver, default size, minimum size, and long localization checks pass.
- [ ] #41's accepted `16/26 pt` padding remains useful at `300 pt` and clips neither content nor the selected ring.
- [ ] No setting causes a bar lifecycle, hotkey, or storage regression.

## Stage 4 — Source themes and Pinboard organization

**Goal:** land the maintainer's preferred small, orthogonal customization features before high-risk data mutation work.

**PR lineage:** combine closed [#34](https://github.com/momenbasel/pesty/pull/34) with closed [#56](https://github.com/momenbasel/pesty/pull/56); #56 corrects #34's migration/default behavior. Closed [#10](https://github.com/momenbasel/pesty/pull/10) is superseded by that combined design. Re-cut Pinboard reorder from closed [#54](https://github.com/momenbasel/pesty/pull/54). Re-cut the Pinboard portion of closed [#58](https://github.com/momenbasel/pesty/pull/58), which supersedes closed [#11](https://github.com/momenbasel/pesty/pull/11). Pause behavior itself was already merged through [#39](https://github.com/momenbasel/pesty/pull/39); do not duplicate its state machine.

### 4A — Source color themes

- [ ] Add one setting with three stable themes: **Default**, **Vibrant**, and **Accent Shades**.
- [ ] Default derives a familiar readable color from the source app icon, matching #56 so an upgrade does not unexpectedly recolor everything.
- [ ] Vibrant is visibly stronger without sacrificing white-header-text contrast.
- [ ] Accent Shades is deterministic per source app across launches and machines; missing icons use a readable stable fallback.
- [ ] Store the theme choice, not a fragile cache of every derived color. Define behavior when an app updates its icon.
- [ ] Remove #34's runtime `#filePath`/source-checkout icon probe. It leaks a local path and causes MAS sandbox denial.
- [ ] Verify direct, MAS, missing-icon, generic-source, light/dark appearance, increased contrast, and reduced transparency.

### 4B — Pinboard reorder

- [ ] Persist Pinboard order device-locally and keep it stable across relaunch. Place newly discovered remote Pinboards deterministically without scrambling the existing local order.
- [ ] Support drag reorder plus **Move Left** and **Move Right** alternatives.
- [ ] Disable unavailable first/last actions. If section navigation wraps, group `(currentIndex + delta)` before modulo.
- [ ] Exclude the Add Pinboard affordance from ordinary section-navigation indices.
- [ ] Do not change CloudKit schema for the initial small reorder PR. Current CloudKit has no order field, so make no cross-device ordering guarantee; if synced order is wanted later, design an explicit additive field, migration, and conflict policy.

### 4C — Inline rename and swatch menu

- [ ] A new Pinboard enters a focused inline rename field immediately.
- [ ] Return commits, Escape cancels, focus loss follows a documented commit/cancel rule, and blank/whitespace-only names are rejected.
- [ ] The Paste Bar key monitor must not consume characters while the field editor is first responder.
- [ ] Existing boards can rename inline. Prefill the explicit stored name, not generated display text.
- [ ] Add the #58 persistent swatch submenu using the existing `colorHex` model/sync field.
- [ ] Pinboard color affects Pinboard identity/chrome; clip headers retain their source-app theme.

### 4D — Pause affordance, only if still wanted

- [ ] If the Paste Bar ellipsis includes Pause/Resume, bind it to the one state already used by the status menu and Cmd-Shift-P.
- [ ] Update title/icon immediately. Pausing stops new capture without changing history, Pinboards, or Paste Stack state.
- [ ] Do not introduce another timer, flag, or hotkey for pause.

**Exit gate**

- [ ] Theme snapshots prove readable contrast for real icons and fallbacks.
- [ ] Device-local reorder persistence, deterministic placement after remote reconciliation, first/last commands, drag cancel, and accessibility actions pass.
- [ ] Rename's first keystroke, Return, Escape, click-away, invalid name, and remote rename cases pass.
- [ ] If optional 4D is selected, pause state remains identical in the status menu, Paste Bar, icon, and shortcut.

## Stage 5 — Clipboard provenance, copy results, and user feedback

**Goal:** make every copy truthful, safe, and testable before building more actions on top of it.

**PR lineage/status:** **KEEP; BLOCKED** open [#17](https://github.com/momenbasel/pesty/pull/17): its [maintainer comment](https://github.com/momenbasel/pesty/pull/17#issuecomment-5247499190) explicitly wants the read path, while the hardcoded write origin, independently resolved ID/name, unvalidated marker, and post-#27 exclusion behavior block merge. Rebase and correct #17 as the focused validated-attribution slice. Closed [#61](https://github.com/momenbasel/pesty/pull/61) remains reference material for a separate `CopyResult`/toast slice; closed [#13](https://github.com/momenbasel/pesty/pull/13) stays superseded.

### 5A — Validated source attribution

- [ ] Write `org.nspasteboard.source` as `validated(item.sourceBundleID) ?? validated(Bundle.main.bundleIdentifier) ?? AppIdentity.bundleIdentifier`.
- [ ] Never hardcode upstream Pesty or Pesty as the origin of content that originally came from another app.
- [ ] Treat an incoming source marker as untrusted. Accept at most 255 characters, require at least one dot, and allow only `[A-Za-z0-9.-]`.
- [ ] Reject invalid markers before LaunchServices lookup, exclusion matching, persistence, CloudKit, icon lookup, or color derivation.
- [ ] Apply the same validation during local-store load, migration, and remote apply so legacy stored source IDs cannot bypass the outbound check.
- [ ] Resolve bundle ID and display name as one pair. If the declared bundle is valid but not installed, do not attach an unrelated frontmost-app name.
- [ ] Apply excluded-app rules to the validated declared source as well as ordinary frontmost/previous-active attribution.

### 5B — `CopyResult` and success-only copy toast

- [ ] Complete every deterministic payload/source preflight **before** calling `NSPasteboard.clearContents()`; a preflight failure must leave the user's current pasteboard untouched.
- [ ] Prebuild the complete one-or-more-item `[NSPasteboardWriting]` payload, attach the same validated provenance consistently (including the first metadata-readable item, with conflict/read-order tests), then call `writeObjects` exactly once after clear. Multi-file/native representations may require multiple items; provenance must not be a second pasteboard mutation.
- [ ] After `clearContents()`, an OS write can still fail. Report that failure, do not paste or toast, and restore the old pasteboard only when a complete lossless snapshot was captured; never promise atomic preservation that AppKit cannot provide.
- [ ] Return a structured copy result that distinguishes content written, source marker written, resulting change count, and copy failure without exposing clipboard contents in logs. Paste/handoff outcome remains a separate Stage 2 result.
- [ ] Preserve the pasteboard change-count suppression and successful-copy history promotion without self-recapture or duplicates.
- [ ] Port #49's copy-promotion behavior here so promotion occurs only after a confirmed successful `CopyResult`, never after a failed or partial write.
- [ ] Support text, plain-text override, RTF, links, colors, images, and files with an explicit success/failure result for each representation.
- [ ] Dismiss the Paste Bar after the user's copy command even when writing fails, as requested in #61's feedback; never proceed to direct paste on failure.
- [ ] Show one concise toast only after a confirmed successful write.
- [ ] The toast must be non-key/non-main, must not reactivate Pesty, and must not disturb the destination app or #64's bar phase.
- [ ] Cancel/obsolete the previous toast dismissal task before showing a newer toast.
- [ ] Select the display using the same current target-screen policy as the bar; do not blindly use `NSScreen.main`.
- [ ] Keep the baseline around `236 x 48 pt`, with short animations near `0.16/0.18 s`; support Reduced Motion.
- [ ] Do not render private clipboard contents, perform network requests, emit telemetry, or log the copied value in the toast.

**Exit gate**

- [ ] Tests cover every payload type, plain-text override, empty/invalid payload, original-source marker, bundle fallback, installed/uninstalled app, malicious/oversized marker, excluded declared source, and self-recapture suppression.
- [ ] Only bounded validated IDs can reach persisted or CloudKit-facing `sourceBundleID` state.
- [ ] A preflight copy failure leaves pasteboard content intact. A post-clear OS write failure is accurately surfaced, attempts restoration only from a lossless snapshot, hides the bar, triggers no paste, and shows no toast.
- [ ] Successful copy promotes history exactly once and shows one non-key toast without focus loss.

## Stage 6 — Collection-scoped deletion foundation and revised retention

**Goal:** define exact record and file ownership before editing, bulk deletion, previews, or Paste Stacks make deletion more dangerous.

**PR lineage:** keep/revise open [#21](https://github.com/momenbasel/pesty/pull/21); its preference migration is useful, but the branch must be rewritten because it replaces the `trimHistory()` API while current-main `applyRemote(clips:)` still calls it, and its local policy can issue account-wide deletes. Keep/revise open [#40](https://github.com/momenbasel/pesty/pull/40): its collection-scoped deletion/image-lifetime foundation lands first, then its required multi-select behavior is redesigned on top. Keep open [#19](https://github.com/momenbasel/pesty/pull/19) for later amendment; closed [#57](https://github.com/momenbasel/pesty/pull/57) supplies only a finished-selection Backspace rule.

### 6A — Legacy per-container identity migration

- [ ] Before **any** History-removal path is enabled, scan the force-disabled legacy Paste Stack data and build a versioned local quarantine/index under `Application Support/Pesty`.
- [ ] For each legacy Stack entry, mint a Stack-owned item ID, record the matching old History ID as explicit provenance when determinable, and clone its asset into quarantine ownership. Default the quarantined follow-history policy to true; isolate unmatched entries for explicit Stage 12 review rather than guessing.
- [ ] Route Stage 6 History removals through this quarantine index so matched legacy entries/assets cascade safely even before the final Paste Stack engine/UI exists.
- [ ] If the Stack quarantine/index migration cannot complete and roll back cleanly, keep Stack UI disabled **and block History deletion/retention** rather than destroying the History-side evidence needed for later provenance cleanup.
- [ ] Before exact edit/delete/multi-select APIs are enabled, scan History and every Pinboard for duplicate `ClipItem.id` values left by the old shared-UUID model.
- [ ] Preserve one canonical History identity and mint independent IDs for every container copy. Represent all future selections/mutations with a concrete container plus item ID.
- [ ] Reconcile image/payload ownership while migrating: clone assets when independent records need independent ownership; never let re-ID leave two owners believing they can delete the same only file.
- [ ] Make the local migration versioned, idempotent, transactional, and rollback-safe. Do not expose partially migrated data after a crash or encode failure.
- [ ] Define the CloudKit sequence for legacy record names: enqueue new independent records and exact old-record tombstones without temporarily erasing the only remote copy or allowing an old device to recreate shared identity.
- [ ] Test upgrade with zero, one, and many duplicate IDs; legacy Stack matches/unmatched entries; missing/shared images; quarantine rollback; offline changes; retry; old/new device reconciliation; and tombstone arrival in either order.

### 6B — Exact single-record deletion

- [ ] Introduce one source/container-scoped delete API. Its input must identify History, a specific Pinboard, or a future specific Paste Stack entry—not merely a UUID assumed to be globally shared.
- [ ] This exact deletion finalizer is the first #40 behavior eligible to land in Stage 6, and it must fix the Pinboard image-file leak identified by the maintainer. Do not cherry-pick scoped-delete commit `829a015` alone—it structurally depends on multi-select foundation `4922251`. Rewrite that semantic fix on current main within the revised #40 work, then rebuild the required multi-select layer safely.
- [ ] Delete only the selected local container record, persist atomically, then queue its exact CloudKit tombstone. Keep this as a separable hard-delete finalizer so Stage 16 can invoke it only after the Undo grace period. Surface/retry sync failure without resurrecting the locally deleted record.
- [ ] Route every History-removal path through one transaction: single delete, bulk delete, Clear History, retention, dedupe/replacement when it truly removes a record, and remote CloudKit tombstones. That transaction owns optional follow-history Stack cleanup.
- [ ] Remove an image or exported payload only when no remaining persisted object references it. Prefer explicit ownership over filename guessing.
- [ ] Repair primary selection, range anchor, search projection, active source, and empty-state UI transactionally.
- [ ] Make remote delete reconciliation use the same invariants without echoing an infinite delete/save cycle.
- [ ] Keep `Clear History` a separate explicit transaction whose scope and Paste Stack interaction are covered in Stage 12.

### 6C — Revised retention policy for open #21

**Revision gate:** keep #21 open, but do not merge or superficially rebase its current implementation. First choose and test its sync contract on current main, then rewrite the branch while retaining only validated preference-migration behavior.

- [ ] For the upstream #21 revision, choose and document one of the maintainer's no-delete contracts: **device-local cache/view pruning invisible to `CloudSyncService.diffAndEnqueue`**, or an **identical deterministic per-device age filter** that converges without any device issuing CloudKit deletes. A local preference must never silently emit account-wide tombstones.
- [ ] If Pesty separately wants synced account-wide retention with additive CloudKit policy/schema, treat it as a new product feature requiring explicit maintainer approval, migration, conflict resolution, and two-device convergence—not as behavior accepted by #21's review.
- [ ] Preserve/adapt current-main `trimHistory()` call sites so every intermediate slice compiles; do not replace them with #21's stale API wholesale.
- [ ] Define history count and age policies independently, with clear Settings copy, bounded inputs, and migration for existing preferences.
- [ ] Preserve the part #21 got right: keep the existing `historyLimit` preference intact and default existing users to item-count mode unless an explicit migration says otherwise.
- [ ] Changing a slider previews the affected count and applies only on release/explicit confirmation. Switching Number/Time modes must not immediately delete data merely because a default value became active.
- [ ] Before a destructive policy change, show the exact local/account scope and deletion count. Make cancellation leave both the setting and data unchanged.
- [ ] Apply the approved active policy deterministically after capture, successful remote reconciliation, an explicitly applied setting change, and launch migration.
- [ ] Retention selects History records. Pinboards never cascade from History retention; when `pasteStacksFollowHistory` is true, linked Stack entries **do** cascade through the one tested history-removal transaction.
- [ ] Under either upstream-safe contract, prune/filter only the local cache/projection without making the record absent from CloudKit desired state or deleting the remote record. Define how filtered remote records avoid immediate reappearance and how clock skew affects deterministic age filtering.
- [ ] Delete an image/payload only after proving no surviving local or sync-owned record references it.
- [ ] Pause and exclusion settings affect capture, not whether an already-expired record is eventually pruned.
- [ ] Avoid save/notification loops: one logical retention transaction, one persistence write, one sync notification.
- [ ] `Forever` still needs a storage/resource contract: bounded thumbnails/cache, compaction, disk-pressure behavior, and truthful warnings. It must not mean an unbounded in-memory or on-disk hot set.
- [ ] Define behavior for clock changes, future timestamps, zero/disabled values, very large limits, corrupt persisted settings, returning/fresh devices with different policy versions, and remote inserts older than the age limit.

**Exit gate**

- [ ] Legacy shared-ID plus disabled-Stack quarantine/cascade migration tests pass locally and through the CloudKit retry/tombstone harness before any History removal or Stages 7–8 are enabled.
- [ ] Tests cover count-only, age-only, both policies, disabled policies, boundary timestamps, clock anomalies, remote-old insert, launch pruning, and settings changes.
- [ ] Retention tests cover slider drag/cancel/apply, Number↔Time switching without surprise deletion, bounded `Forever`, fresh and returning devices, differing local preferences, offline changes, and the chosen cross-device contract; a local-only policy must prove it emits zero unintended `deleteRecord` operations.
- [ ] Tests cover identical content in multiple containers, distinct IDs, deliberately shared legacy filenames, missing files, and remote deletion.
- [ ] No Pinboard or future stack record disappears merely because a History record with related content is pruned or deleted.
- [ ] No still-referenced PNG or payload file is removed.

## Stage 7 — Clip mutation engine, editor, and context menu

**Goal:** establish safe data mutation first, then a native editor, then context-menu actions that reuse those services.

**PR lineage:** keep/revise open [#42](https://github.com/momenbasel/pesty/pull/42). Its maintainer comment explicitly accepts key-monitor scoping and `pasteTarget` as the first Stage 2 foundations, while the 921-line combined branch is blocked because edit mutations can trigger CloudKit deletion, shared UUID assumptions are stale, and the app lacks the native menu needed for Cmd-C/V/Z/A/F. The full context menu/editor feature remains required; rebuild it after those foundations and the current per-container mutation model. The local prototype is reference, not proof of completed semantics. Closed [#32](https://github.com/momenbasel/pesty/pull/32) is not a reason to combine editor settings with this work.

### 7A — Approve mutation semantics before UI

- [ ] v1 edits exactly the selected record in its exact container; it never propagates to a Pinboard/history sibling by old UUID or equal content.
- [ ] Preserve the record UUID for an in-place edit and issue the exact sync update for that container.
- [ ] Define the equality key as the canonical payload fingerprint **within one concrete container**. Reject a save that collides with another record in that container; equal content in a different container remains independent and valid.
- [ ] Capture a record revision/version when the editor opens. On Save, reject and offer reload/copy-draft choices if a newer remote/local revision exists; if the record was deleted, never resurrect it implicitly.
- [ ] Do not bump a timestamp, promote history, or rewrite the system pasteboard as an undocumented side effect.
- [ ] Expose **Save & Copy** distinctly from **Save** only if wanted. Save happens first; if Save succeeds but Copy fails, report “saved, not copied.” If Save fails/conflicts, do not copy.
- [ ] Implement a pure mutation layer for text, RTF, links, and colors with complete pre-validation, one atomic local persistence change, and one queued sync update.
- [ ] Define which image/file metadata is editable. Do not pretend to edit an external file's bytes in v1.

### 7B — Native editor UI

- [ ] Require Stage 2's native App/Edit/Window menus first.
- [ ] Start near `760 x 560 pt`, allow resizing down to about `520 x 380 pt`, and preserve at least `260 pt` for the main editor where possible.
- [ ] Save with Cmd-Return; Cancel with Escape; plain Return remains newline input.
- [ ] Support native Undo/Redo, Cut/Copy/Paste, Select All, Find, spelling, and accessibility.
- [ ] Show validation errors inline without discarding the user's draft or changing the stored clip.
- [ ] Writing Tools may be offered for eligible text only through explicit user action and availability checks; never run it automatically.
- [ ] A title field must prefill `customTitle ?? ""`, not a generated `displayTitle`.
- [ ] Closing/saving must clear preview/controller lifecycle state so an edited clip cannot resurrect a closed preview.

### 7C — Context menu in safe layers

- [ ] First land read-only/non-destructive actions: **Paste to _App_**, **Paste as Plain Text**, **Copy**, and **Preview**.
- [ ] Titles, enablement, and destination must be derived from the clicked clip and the destination resolved at action time.
- [ ] Scope commands to the menu's originating card; closing a menu must invalidate stale closures/targets.
- [ ] Right-clicking a selected card acts on the current selected set for actions explicitly supporting multiple items; right-clicking an unselected card first scopes the context to that one card. Single-item-only actions must say so and target the primary/clicked item deterministically.
- [ ] Add **Share** only as an explicit action, constructing the minimum correct payload without background network activity.
- [ ] Add **Rename Title** using explicit custom-title semantics.
- [ ] Add **Pin to…** and **New Pinboard…** only through per-container-copy APIs that mint the correct identity and owned assets.
- [ ] Add **Delete** only through Stage 6's exact collection-scoped deletion API.
- [ ] Add **Edit…** only after 7A/7B are merged and tested.
- [ ] Keep destructive actions separated at the bottom and confirm when an action affects more than one record.

**Exit gate**

- [ ] Mutation tests cover canonical same-container collisions, allowed cross-container equality, stale revision, remote delete while open, UUID stability, exact sync apply/delete, invalid URL/color/RTF, unchanged clipboard, Save & Copy partial failure, and one save notification.
- [ ] Editor tests/manual QA cover all standard commands, Save/Cancel, window resize, invalid drafts, focus restoration, and preview close behavior in MAS and direct builds.
- [ ] Menu tests cover dynamic destinations, clicked-card scoping, plain-text paste, copy, preview lifecycle, custom-title rename, pin/create, source-scoped delete, and share payload.
- [ ] Opening/closing an editor or context menu never strands, re-shows, or prematurely hides the #64 Paste Bar.

## Stage 8 — Multi-select and bulk deletion

**Goal:** make selection explicit and safe across filtering, live capture, source changes, and sync before enabling destructive bulk actions.

**PR lineage:** keep/revise open [#40](https://github.com/momenbasel/pesty/pull/40): land its explicitly accepted collection-scoped deletion/image-ownership foundation in Stage 6, then complete the still-required multi-select behavior with event-carried modifiers and per-container IDs here. Keep open [#19](https://github.com/momenbasel/pesty/pull/19): the maintainer's minimum unblock is repeat suppression, with exact scope, adjacent selection, docs, and tests also requested. This roadmap imposes the stricter Pesty release policy that the shortcut remains interim until Stage 16 Undo. Closed [#57](https://github.com/momenbasel/pesty/pull/57) is only a seven-line bulk-delete follow-up and must be folded into the finished selection model. Revised #37 search sizing lands in Stage 2; this stage only proves selection remains correct while filtering.

### 8A — Selection state model

- [ ] Represent primary, selected set, and range anchor as `ClipLocation`/`RecordKey(container, itemID)` values everywhere, or keep a fully independent `SelectionState` per concrete container. Never store a bare UUID and infer its collection later.
- [ ] Reconcile selection on source switch, query change, incoming capture, retention prune, local delete, remote insert/update/delete, and empty/non-empty transitions.
- [ ] Incoming clips must not silently collapse a deliberate multi-selection.
- [ ] Return pastes only the visually distinct primary card. Clicking, keyboard navigation, and range selection must update primary/anchor by documented rules.
- [ ] Filtered selection may retain hidden records only if the delete count and confirmation make that scope unmistakable. Safer default: bulk actions operate on the visible source-scoped projection.

### 8B — Input behavior

- [ ] Use the mouse/key event's captured modifiers at click time. Never read global/live `NSEvent.modifierFlags` later from a delayed SwiftUI tap gesture.
- [ ] Normal click selects one; Cmd-click toggles; Shift-click extends a contiguous range in current visible order.
- [ ] Arrow navigation preserves or collapses selection according to familiar macOS rules and always leaves a valid primary item.
- [ ] With a non-empty query, Backspace—including ordinary repeat events—edits the query before it can delete clips.
- [ ] Once the query becomes empty, consume repeated Backspace events without deleting; require a fresh physical key-down for deletion and add a short post-search-empty cooldown so clearing text and deleting are separate intents.
- [ ] With an empty query and a fresh key-down, Backspace and Forward Delete use the same source-scoped delete command. A Pinboard action must not erase a related History or other Pinboard record.
- [ ] After deleting, select the adjacent record at `min(oldIndex, remainingCount - 1)`, not the newest history item. Update both README references and decide/document whether Cmd-Backspace remains supported.
- [ ] The maintainer's minimum #19 unblock is `!event.isARepeat`; this roadmap's stricter local release policy keeps the user-facing shortcut disabled or explicitly interim until Stage 16 supplies the five-minute Undo journal. Do not attribute that extra gate to the maintainer.

### 8C — Bulk deletion

- [ ] Preflight the exact source-scoped target set and asset ownership before presenting the action; the label and count must equal that immutable preflight set.
- [ ] Confirm deletion of more than one clip. Before Stage 16, state accurately that the checkpoint has no undo and is not release-ready; after Stage 16, state the five-minute grace period and when sync deletion becomes final.
- [ ] Apply Stage 6's exact deletions and newly unreferenced asset changes in one atomic local persistence transaction. If local persistence fails, commit none of it.
- [ ] After the local hard-delete commit, queue exact CloudKit tombstones. A sync failure is retryable/surfaced sync state; it is not a per-record local “partial failure” and must not roll back the successful local transaction. Stage 16 later routes manual bulk deletes through its journal and calls this path only at expiry.
- [ ] Repair primary, selected set, range anchor, search projection, scroll target, and empty source after completion.
- [ ] Do not delete Pinboard/history siblings or shared legacy PNGs because content or stale IDs happen to match.

**Exit gate**

- [ ] Tests cover normal/Cmd/Shift click timing, range direction, query subset, a held Backspace through the final query character, repeat suppression, cooldown boundary, adjacent selection after repeated deletes, Pinboard scoping, incoming clip, source switch, primary Return target, sync reconciliation, confirmation threshold, Backspace, Cmd-Backspace, and Forward Delete.
- [ ] Image-reference tests and two-container/two-device simulations show no unrelated record or file is deleted.
- [ ] VoiceOver announces selected count and primary item; selection remains distinguishable without color.

## Stage 9 — Safe drag-out

**Goal:** expose correct lazy pasteboard/file representations and tie dismissal to the actual drag-session outcome.

**PR lineage:** keep open [#16](https://github.com/momenbasel/pesty/pull/16) and redesign it before proposing merge. The maintainer explicitly wants drag-out but rejects its uncancellable 80 ms hide timer. Closed [#59](https://github.com/momenbasel/pesty/pull/59) is useful test/provider source material, but it also hides too early, supports only one file, eagerly encodes images, and misses native URL/color types. Rebase only after test infrastructure and preserve #64's presentation generation.

### 9A — Lazy providers

- [ ] Text: UTF-8 plain text; RTF: RTF plus plain-text fallback.
- [ ] Links: `public.url` plus text fallback only for approved credential-free schemes (initially `http`/`https`). Local file clips use file-URL representations; unsupported link schemes remain text.
- [ ] Colors: a real `NSColor` representation plus normalized hex text.
- [ ] Files use all-or-nothing preflight for v1: vend every existing local file URL in a multi-file clip, or reject the drag with a clear unavailable reason if any entry is stale/malformed. The advertised provider count must exactly match the files delivered.
- [ ] Images: register TIFF/PNG lazily. Do not synchronously read disk or fully re-encode on the MainActor when the drag starts.
- [ ] Use unique, extension-bearing suggested names. Resolve collisions deterministically and avoid exposing managed internal paths when an exported copy is appropriate.
- [ ] Bound export size/lifetime and apply the `0700` directory / `0600` file rules.

### 9B — Drag lifecycle

- [ ] Do not hide at drag threshold or session start.
- [ ] Advertise a copy-only source operation mask so Finder or another destination can never move/delete an original or Pesty-managed asset.
- [ ] Let ordinary resign-key behavior hide when a real destination activates, or dismiss from `draggingSession(_:endedAt:operation:)` only after a successful external operation.
- [ ] Escape, a refused destination, a click that barely crosses the drag threshold, and a local/no-op drop must preserve the bar, query, selection, and #64 phase.
- [ ] Any completion token must be tied to the current epoch so it cannot hide a newly reopened bar.
- [ ] Dragging multiple selected clips, if supported, must define order and partial-provider failure. Otherwise clearly limit v1 to the primary clip.

**Exit gate**

- [ ] Provider tests load and inspect the actual representation for text, RTF, URL, color, image, one file, multiple files, stale files, and collision names.
- [ ] Performance test proves image bytes are loaded lazily/off the MainActor.
- [ ] UI/session QA covers Escape, refused target, successful Finder/TextEdit/browser drops, and immediate hotkey reopen.

## Stage 10 — Privacy-safe local previews

**Goal:** ship useful previews without any silent network behavior, insecure files, focus theft, or lifecycle regressions.

**PR lineage:** closed [#8](https://github.com/momenbasel/pesty/pull/8) proved the feature but was rejected for three silent requests per copied URL, no opt-out, insecure plaintext temp files, and architectural conflicts. Closed [#28](https://github.com/momenbasel/pesty/pull/28) is a newer floating-preview direction. Closed [#45](https://github.com/momenbasel/pesty/pull/45) is the compact detached-preview reference; fold closed [#46](https://github.com/momenbasel/pesty/pull/46)'s tiny non-key/duplicate-shadow correction into it. Closed [#47](https://github.com/momenbasel/pesty/pull/47) and [#51](https://github.com/momenbasel/pesty/pull/51) are later external-open/configuration references.

### 10A — Native Quick Look only

- [ ] Implement local Quick Look without instantiating or calling a link-metadata network store.
- [ ] Never hand an `http`/`https` URL or `.webloc` directly to Quick Look, because the OS previewer may fetch it. Render remote links as locally generated plain text/static HTML with no remote subresources until the user explicitly opens or enriches them.
- [ ] Export text, RTF, colors, or in-memory images to uniquely named owner-only files only when Quick Look requires a file.
- [ ] Create the temp directory as `0700`, each file as `0600`, and remove exports on dismissal, app termination, and bounded startup cleanup.
- [ ] Never delete a broad/shared temp directory used by upstream Pesty or another process.
- [ ] Space toggles Quick Look; arrows track the primary card; typing spaces into an active search/editor field remains normal text input.
- [ ] Missing/stale files produce a safe unavailable state without crashing or exposing a path.

### 10B — Detached inline preview panel

- [ ] Keep the preview non-key and non-main so keyboard focus remains in the Paste Bar.
- [ ] Anchor above the selected card rather than increasing the bar height. Start around `500 x 340 pt`, clamp to `360...540 x 260...420 pt`, keep `20 pt` from screen edges, and keep the pointer `34 pt` from preview corners.
- [ ] Keep the selected card visible; flip/adjust or fall back gracefully when there is not enough room above the bar.
- [ ] Use one shadow only. Closing must clear both the controller's item and presentation state.
- [ ] Source switch, search, delete, edit, and remote changes must update or dismiss the preview deterministically.
- [ ] Use #63 screen targeting and #64 epochs. Force-dismiss on sleep/display changes without resurrecting the bar.

### 10C — Explicit external open

- [ ] Validate URL schemes before opening links; initial allow-list should be `http`/`https` for browsers and existing local files for file apps.
- [ ] Open text/images from owner-only exported copies so external edits cannot mutate Pesty-managed history assets. Use a unique `0700` directory per operation and verify the final exported file mode is `0600` after writing/replacing it.
- [ ] Clean the `Pesty-Open` directory with a bounded TTL plus startup/termination and explicit replacement cleanup. Do not delete an export merely because `NSWorkspace.open` returned; the destination may not have finished reading it.
- [ ] Provide browser/Preview/TextEdit actions only when compatible; keep one-off app choice scoped to the current item.
- [ ] Split the opener implementation and its Settings UI if together they exceed a focused review size.

**Exit gate**

- [ ] A mocked URL loader proves **zero network requests** in all default/local preview paths.
- [ ] Tests cover permissions, cleanup, invalid schemes, missing files, non-key behavior, selection changes, edit/delete lifecycle, sleep/wake, and display changes.
- [ ] External edits cannot modify Pesty's managed stored file.
- [ ] MAS/direct builds and Debug Demo screenshots pass on small, large, and stacked displays.

## Stage 11 — Optional link enrichment

**Goal:** add network-derived link information only as a separate, explicit privacy feature after local previews are complete.

**PR lineage:** the network portions of closed [#8](https://github.com/momenbasel/pesty/pull/8), [#28](https://github.com/momenbasel/pesty/pull/28), and [#45](https://github.com/momenbasel/pesty/pull/45) are references only. Their automatic HTML, Open Graph image, and favicon fan-out is not acceptable as a default.

- [ ] Add a clearly worded **Fetch link preview metadata** setting that defaults to **off**, including upgrades and missing-default migrations.
- [ ] Do not fetch when a URL is merely copied, synced, rendered as a card, selected, or shown in local Quick Look.
- [ ] Prefer a user-initiated fetch when the user explicitly opens a link preview. If any automatic-on-preview behavior remains, say so in the setting and privacy copy.
- [ ] Permit only credential-free `http` and `https`. Resolve and validate the initial host and every redirect against IPv4/IPv6 loopback, private, link-local, ULA, multicast, unspecified, and IPv4-mapped forbidden ranges; reject a request if any resolution is unsafe.
- [ ] Prevent DNS-rebinding TOCTOU: the actual connected peer for the metadata request and the optional image request must be one of that hop's validated public addresses. Use a transport that pins the validated resolution while preserving TLS hostname/SNI validation, or an equivalent trusted proxy; ordinary preflight DNS followed by an independent URLSession resolution is insufficient.
- [ ] Disable cookies, persistent credential storage, authentication forwarding, and cross-origin sensitive headers. Revalidate after every redirect and fail closed on ambiguous DNS results.
- [ ] Cap one user action to at most **two** requests: one metadata document and at most one chosen preview image—no automatic favicon fan-out. Initial limits: 3 redirects, 10 seconds total, 1 MiB HTML, 5 MiB encoded image, 4096×4096 decoded pixels, 2 concurrent preview jobs, and 50 MiB cache; changes require tests and documented rationale.
- [ ] Use an ephemeral or deliberately bounded cache; key it without leaking complete sensitive URLs into logs or filenames.
- [ ] Support cancellation when selection changes, preview closes, the bar hides, the setting turns off, or the app terminates.
- [ ] Turning the setting off must cancel work and prevent every subsequent request; decide whether cached metadata is deleted and state that behavior.
- [ ] Review and update App Store privacy nutrition disclosures, in-app privacy text, website privacy page, and release notes before shipping.
- [ ] Render a compact loading/failure state without moving the panel, stealing focus, or blocking local URL/text information.

**Exit gate**

- [ ] Network-mock tests assert zero requests while disabled and exactly the bounded expected request sequence after explicit opt-in/action.
- [ ] Tests cover redirects, oversized HTML/images, malformed metadata, cancellation, offline mode, cache eviction, private/invalid schemes, and setting disable during a request.
- [ ] Security review confirms no local-network probing, arbitrary file access, credential forwarding, unbounded decode, or sensitive URL logging.
- [ ] Privacy disclosures accurately describe the shipped request behavior.

## Stage 12 — Paste Stack identity, persistence, and privacy redesign (2.1.0)

**Goal:** build a tested state engine with correct identity and erase semantics before exposing the feature.

**PR lineage:** Paste Stacks are the separate 2.1.0 feature release, following the upstream tracker. Closed [#9](https://github.com/momenbasel/pesty/pull/9), [#29](https://github.com/momenbasel/pesty/pull/29), [#30](https://github.com/momenbasel/pesty/pull/30), [#31](https://github.com/momenbasel/pesty/pull/31), [#33](https://github.com/momenbasel/pesty/pull/33), [#43](https://github.com/momenbasel/pesty/pull/43), [#44](https://github.com/momenbasel/pesty/pull/44), [#48](https://github.com/momenbasel/pesty/pull/48), [#53](https://github.com/momenbasel/pesty/pull/53), and [#55](https://github.com/momenbasel/pesty/pull/55) are a cumulative stale stack, not reopen candidates. The decisive maintainer plan is in [#55's close comment](https://github.com/momenbasel/pesty/pull/55#issuecomment-5247469612).

### 12A — Product and sync contract

- [ ] Decide and document whether 2.1.0 Paste Stacks are device-local or synced. **Recommended first release: device-local**, behind a default-off feature toggle, until the state engine and erase behavior are proven.
- [ ] Do not leave sync behavior implicit or different without explanation between direct/iCloud Drive and MAS/CloudKit builds.
- [ ] `pasteStacksEnabled` defaults to false. Disabling stops capture, unregisters only the stack shortcut, dismisses stack surfaces, and leaves the primary Pesty hotkey intact.
- [ ] Settings must say that disabling is **not deletion**: saved local stacks and payloads remain until **Delete All Paste Stacks** or a documented follow-history cascade removes them.
- [ ] `pasteStacksFollowHistory` defaults to **true**. Missing/legacy values must migrate safely to the privacy-preserving behavior.
- [ ] If users may set follow-history false, explain that saved payloads remain after Clear History and provide a separate **Delete All Paste Stacks** action.

### 12B — Identity and CloudKit boundary

- [ ] Give every stack and stack entry its own stable ID.
- [ ] A stack-owned clip snapshot must mint its own `ClipItem.id`; never reuse a History or Pinboard UUID.
- [ ] If history-following cleanup needs provenance, store an explicit optional relationship such as `originHistoryID`. Do not infer a relationship from equal UUIDs or equal content.
- [ ] Current CloudKit indexes `Clip` records globally by `ClipItem.id`; `container` currently means History or a Pinboard UUID. Do not overload it with a stack UUID without an explicit Mac+iOS schema/apply-path design.
- [ ] If stack sync is later approved, add explicit `PasteStack`/`PasteStackEntry` records with ordering, conflict, tombstone/delete, migration, and two-device convergence tests.
- [ ] Keep stacks entirely out of `CloudSyncService` for the device-local 2.1.0 release. Do not partially upload entries as ordinary clips.
- [ ] A device-local 2.1.0 release must use a separate store under local `Application Support/Pesty`, or explicitly omit all Stack fields/assets from the main iCloud Drive snapshot. “Not in CloudKit” alone is insufficient because direct builds may place the main `store.json` in iCloud Drive.
- [ ] Remove old helper logic that updates/deletes across collections by equal UUID (`containsHistoryItemID`-style assumptions).

### 12C — Persistence and asset ownership

- [ ] Build a non-singleton `PasteStackStore`/state engine with injected persistence, clock, and asset storage. Keep AppController as orchestration, not a second store.
- [ ] Version local persistence, decode missing/old fields safely, write atomically, and recover gracefully from corrupt files or missing assets.
- [ ] Before exposing the UI, verify and import Stage 6's quarantine/index into the final Stack store without changing its new IDs, provenance, privacy default, or cloned ownership. Require an explicit safe resolution for unmatched entries; never infer provenance from content alone.
- [ ] If upgrading a checkout that lacks the Stage 6 manifest, run that same minimal privacy migration gate first. Final import remains transactional/resumable; a move or encode failure must roll back without deleting the quarantine entry or its only asset.
- [ ] Persist in Pesty-specific storage with `0700` directories and `0600` files where applicable.
- [ ] Clone an image/payload into stack ownership when an entry is created. Never share the History filename as if the stack owns it.
- [ ] Delete only the owning entry's asset after a successful model/persistence transaction.
- [ ] Orphan cleanup must first prove that no persisted History, Pinboard, or Stack record references the file.
- [ ] With follow-history true, every Stage 6 History-removal path—single delete, bulk delete, Clear History, retention, true dedupe/replacement removal, and remote tombstone—must remove linked entries, drop empty stacks, repair active stack/selection, persist, then delete newly unreferenced owned assets.
- [ ] Apply pause, excluded-source, concealed/transient, and remote-ingest privacy filters before anything enters a stack.

### 12D — Tested state engine, no UI

- [ ] Implement new, activate, collect, pause, resume, delete, and reset stack operations.
- [ ] Implement add, remove, re-add, next paste, specific paste, and progress reset.
- [ ] Keep pending entries before pasted entries and define adjacent-stack promotion/empty-stack cleanup.
- [ ] Define duplicate policy deliberately: same origin twice, same content from different apps, and the same clip in multiple stacks.
- [ ] Make mutations transactional: update model, persist, then remove unreferenced assets. Failed encoding must not delete the only payload.
- [ ] Add Codable round-trip, migration, corrupted-store, missing-asset, and interrupted-write recovery tests.

**Exit gate**

- [ ] No Paste Stack UI is enabled until all state-engine, identity, persistence, and Clear History tests pass.
- [ ] No main `store.json`, Stack store/database, or asset directory contains a followed Stack payload after the relevant History-removal transaction.
- [ ] A History edit/delete cannot mutate or delete an independently saved Stack/Pinboard copy.
- [ ] A device-local 2.1.0 build performs **zero Paste Stack CloudKit writes and zero Paste Stack iCloud Drive writes**. If Mac-only Stack sync is explicitly approved for 2.1.0, prove convergence between Macs; any Mac↔iOS Stack sync design belongs to the 2.5.0 train and must converge without changing existing record meanings.

## Stage 13 — Paste Stack capture, paste, and user experience (2.1.0)

**Goal:** expose one coherent workflow on top of Stage 12, then add reorder/search/save as small follow-ups.

### 13A — Capture and paste integration

- [ ] Register the stack shortcut through the current resilient `HotKeyCenter`; failure must not unregister or replace the primary hotkey.
- [ ] Capture only while the feature is enabled and the active stack is collecting.
- [ ] Clone the canonical stored History item after dedupe/retention settles instead of retaining a transient monitor object.
- [ ] Resolve the destination at paste time through Stage 2's current `pasteTarget`; do not pin every paste to the app active when collection began.
- [ ] Preserve direct/MAS behavior and #63/#64 lifecycle rules.
- [ ] Handle target termination, Accessibility denial, physical modifiers, rapid hotkey/arrow/Return sequences, sleep/wake, and docking.

### 13B — Minimum complete surface

- [ ] Ship one coherent surface with **New/Start**, **Pause/Resume**, pending count, **Paste Next**, remove entry, reset progress, and delete stack.
- [ ] Use **Add to Paste Stack** unless the History record is actually removed. Do not call a hidden/duplicated item “moved.”
- [ ] Keep Clipboard, Pinboard, and Stack selections independent. Disabling/deleting a stack returns to a valid Clipboard selection.
- [ ] Compact and full presentations must share components/state instead of duplicating drag/reorder logic.
- [ ] Keep the tray near `318 x 420 pt`, at least `22 pt` from screen edges and about `14 pt` above the bar, but adapt to the visible frame rather than clipping.
- [ ] A short bar may use a compact deck around the prototype's `300 pt` threshold only if every core action remains reachable.
- [ ] Add labels, counts, progress, VoiceOver, keyboard navigation, destructive confirmation, and non-drag alternatives.

### 13C — Reorder and search follow-ups

- [ ] Reorder pending entries only; keep pasted entries after the pending boundary.
- [ ] Land Move Up/Down and state tests before drag UI. Cover first, last, end-drop, cancelled drop, and off-by-one cases.
- [ ] Search the active stack's displayed projection without mutating its persisted queue order.
- [ ] Repair selection after query edits, paste, delete, reset, re-add, remote/state changes, and no-results transitions.
- [ ] Show a clear no-results state while preserving the underlying queue.

### 13D — Paste/save follow-ups

- [ ] Paste exactly the next or specifically chosen entry per user action into the **currently resolved** destination using the same validated copy/handoff pipeline as History. Batch “paste remaining sequence” is out of scope unless separately designed with per-entry target validation, cancellation, timing, and MAS/direct tests.
- [ ] Saving a stack as a Pinboard clones each entry with a new Pinboard-specific UUID and independently owned assets.
- [ ] Preserve displayed paste order and roll back the entire save if any required clone fails.
- [ ] Prove later Stack/History edits or deletes cannot affect the saved Pinboard.
- [ ] Fold #48's tiny delete/promote behavior into the appropriate tested deck/core slice; never revive #48 independently.

**Exit gate**

- [ ] Unit tests cover all state operations, identity isolation, duplicates, progress, reorder, search projection, save rollback, and selection repair.
- [ ] Manual payload matrix covers text, RTF, links, colors, images, image files, ordinary/multiple files, stale URLs, missing assets, duplicates, and large payloads.
- [ ] Manual lifecycle matrix covers toggle enable/disable, collect/pause/resume, relaunch, Clear History follow true/false, retention, delete-all, active delete, search, reorder, save, exclusions, direct/MAS, and Accessibility on/off.
- [ ] Ship behind the default-off feature setting until migration, data erasure, relaunch, and regression QA are clean.

## Stage 14 — Liquid Glass and final visual polish

**Goal:** adopt modern materials only after the behavior is stable, while retaining macOS 14/15 fallback and the current display lifecycle.

**PR lineage/status:** **Keep/Revise; blocked** open [#14](https://github.com/momenbasel/pesty/pull/14), but propose it only after the Xcode/toolchain and stable-bar work below; its [maintainer comment](https://github.com/momenbasel/pesty/pull/14#issuecomment-5247447945) accepts the Liquid Glass direction and lists exact blockers. **Keep/Revise; blocked on Stage 3/#41** open [#15](https://github.com/momenbasel/pesty/pull/15); its [maintainer comment](https://github.com/momenbasel/pesty/pull/15#issuecomment-5247494659) likes the card-body direction but rejects the shared text palette's Dark Mode result. #41's padding-only revision lands in Stage 3 before #15. Closed [#62](https://github.com/momenbasel/pesty/pull/62) did not satisfy toolchain/workflow, corner, tint, or shadow requirements. Closed [#52](https://github.com/momenbasel/pesty/pull/52) may contribute only safe card-edge/spacing residue; its window animation is superseded by #63/#64. Closed [#26](https://github.com/momenbasel/pesty/pull/26) proved that adding `.toggleStyle(.switch)` changed nothing and should remain dropped.

**Landing order inside this stage:** Stage 3's #41 padding → rebased #15 palette/card work → Xcode/toolchain decision → rebased #14. Do not merge #14 before the final card/chrome palette and #63/#64-compatible bar composition are known.

### 14A — Toolchain decision

- [x] Pin Xcode **26.3** as the initial build SDK requirement while retaining the intended macOS 14 deployment target; record an explicitly approved replacement version before changing the pin.
- [x] Select that exact Xcode 26.3 toolchain in both CI and release workflows; update CONTRIBUTING. Pin third-party setup actions to immutable SHAs, or use a verified installed developer path.
- [ ] Keep a macOS 14/15 compile/runtime fallback and record real results on both OS versions before release. Availability checks do not make a new SDK symbol compile under Xcode 16.

### 14B — Material implementation

- [ ] Use availability-gated `NSGlassEffectView` on macOS 26 and the existing visual-effect fallback on macOS 14/15.
- [ ] When the bar is flush with the visible-frame bottom, do not reveal rounded bottom notches. Extend/clip material so only appropriate top corners read as rounded.
- [ ] Use `Color.clear` behind glass and tint through the glass API; do not stack the prototype's old 34% panel tint with glass tint.
- [ ] Use one shadow. Avoid simultaneous panel, hosting view, glass, and duplicate card shadows.
- [ ] Preserve #63's fixed panel/content slide and #64's phase/epoch/backstop exactly.
- [ ] Respect Reduce Transparency, Increase Contrast, Reduce Motion, dark/light appearance, and accent changes.

### 14C — Card/search/spacing polish

- [ ] Revalidate Stage 3's accepted #41 top `16 pt` / bottom `26 pt` padding across every allowed bar height and Glass/fallback appearance; do not restore the rejected alignment machinery.
- [ ] Rebase #15 after #41 so the same strip-padding hunk lands once. Preserve the liked card-body/icon/ring hierarchy, but split white `chromeText*` tokens from dark `cardText*` tokens; never flip shared window chrome text to black on a dark `.hudWindow`.
- [ ] Keep white/readable `chromeText*` for BarView, empty state, search, menus, and Pinboard tabs; use dark `cardText*` only for light card bodies. Do not turn the whole bar light unless panel appearance and field/pill backgrounds are retuned as one coordinated change.
- [ ] Give the selected-card inner stroke real contrast, remove the unnecessary `.scrollClipDisabled()`, and verify Dark/Light, Increase Contrast, source themes, long titles, missing icons, and the `6 pt` selected ring before proposing #15.
- [ ] Keep visible cards `215 pt` wide with about `28 pt` gaps unless screenshots and navigation tests justify a coordinated token change.
- [ ] Ensure collapsed/expanded search, resize handle, Pinboard tabs, deck cards, inline preview pointer, and selection ring align to a shared grid.
- [ ] Do not reintroduce #52's whole-window slide below another display or weaker lifecycle booleans.

**Exit gate**

- [ ] CI/release compile with pinned Xcode 26.3; direct and MAS paths keep the macOS 14 deployment target.
- [ ] Recorded runtime visual QA on macOS 14, 15, and 26 shows readable content, correct corners, one shadow, and appropriate fallbacks before release.
- [ ] Debug Demo screenshots cover minimum/default/maximum bar size, no/one/many clips, search, selected edge cards, preview, stack tray, resize, Reduce Transparency, and mixed/stacked displays.
- [ ] Dark Mode search/menu/Pinboard chrome meets contrast targets while text on light card bodies remains readable; Stage 3's `16/26 pt` padding at `300 pt` clears the ring without shadow bleed into the top bar.
- [ ] Ten interrupted show/hide/resize cycles produce no cross-display animation or stale completion.

## Stage 15 — 2.5.0 iOS companion, extensions, Mac↔iOS sync, and release readiness

**Goal:** prepare the 2.5.0 companion train as a self-contained release that can be installed, erased, tested, and paired with the Mac without upstream credentials or identity collisions. This stage does not block macOS 2.0.0 or the 2.1.0 Paste Stacks release; 2.5.0 tagging waits for its applicable Stage 16 gates.

### 15A — iOS companion contract

- [x] Product, target, project, scheme, test host, bundle IDs, CloudKit entitlement constant, and visible names are Pesty-specific.
- [x] `PRODUCT_MODULE_NAME=Pesty` is retained so existing `@testable import Pesty` and model names compile.
- [x] Generic iOS Simulator build-for-testing and the existing three tests pass.
- [x] Implement live library sync rather than a readiness-only companion, and label simulator builds accurately as local-only.
- [x] Consume the exact macOS CloudKit schema and handle per-container UUIDs, conflicts, deletes, images, migration, and durable offline work.
- [ ] Verify insert/update/delete/conflict/image/order convergence on two physically signed devices after provisioning.
- [x] Keep the iOS local support directory Pesty-specific and update every “iCloud Drive/Pesty” instruction to the actual fork path/container behavior.
- [x] Fix `iOSApp/Pesty/Sync/LibrarySyncing.swift` so CloudKit errors interpolate `error.localizedDescription`; prohibit clipboard content in logs.
- [ ] Register/provision `iCloud.com.alvst.pesty` under the fork maintainer's Apple Developer team before physical-device testing; simulator success is not device entitlement proof.

### 15B — Signing and packaging

- [ ] Parameterize Developer ID, MAS distribution/installer certificates, Team ID, App Store application identifier, provisioning profile, and notarization API credentials.
- [x] Do not retain or silently default to Moamen's Team `H3WXHVTP97`, certificates, profiles, or API-key paths.
- [ ] Direct local ad-hoc builds may use the stable custom designated requirement; document that changing the signature later can require a fresh Accessibility grant.
- [ ] Produce only `Pesty.app`, `Pesty.icns`, Pesty DMG/ZIP/PKG names, and Pesty volume labels.
- [ ] Remove upstream Homebrew install text from fork release notes because it installs the other app.
- [x] Keep signing/notarization workflows manual until valid secrets and App IDs exist. Do not restore a known-failing tag-triggered release.

### 15C — Final regression and release documentation

- [ ] Run the complete automated suite in direct, MAS-conditional, universal, and iOS simulator modes from a clean checkout.
- [ ] Run the manual matrices in this document on Apple Silicon and the universal/Intel slice where possible.
- [ ] Verify Accessibility denial/grant/revocation, Login Items, launch at login, pause, sleep/wake, display attach/detach, and target-app termination.
- [ ] Verify fresh install, upgrade, corrupt settings/store, missing image, Clear History, delete account data, and uninstall/reinstall behavior.
- [ ] Update README, CONTRIBUTING, changelog, website, privacy, support, About, Settings help, and release notes with actual behavior and Pesty screenshots.
- [ ] Document that Pesty starts with separate storage. If the fork maintainer wants an upstream-data snapshot, provide a manual one-time copy procedure that requires both apps to be quit.
- [ ] Document network preview default, Paste Stack persistence/sync, Clear History behavior, and the shared system pasteboard accurately.
- [ ] Do not tag 2.5.0 yet. Carry its clean release candidate into Stage 16, then repeat the affected deletion/sync/release gates.

**Stage 15 exit gate**

- [ ] A clean clone can build without missing untracked entitlements, identity files, generated project inputs, or local-only absolute paths.
- [ ] The packaged app and iOS build contain no upstream bundle ID, Team ID, storage/temp path, executable name, icon name, or release artifact label.
- [ ] Pesty and Pesty can coexist without sharing defaults/history/storage/login identity; their intentionally shared system pasteboard behavior is documented.
- [ ] Every shipped feature has tests, user-facing help, accurate privacy behavior, and a recoverable data-erasure path.

## Stage 16 — Five-minute Undo for deleted items and per-train release gates

**Goal:** make user-initiated item deletion recoverable for exactly five minutes while preserving exact CloudKit deletion semantics after the grace period, then run the relevant subset for each release train: History/Pinboards in 2.0.0, Paste Stacks in 2.1.0, and companion/sync behavior in 2.5.0.

**Origin:** new Pesty requirement; no audited upstream PR implements this contract.

### 16A — Scope and user contract

- [ ] Make user-initiated single-item and bulk-item deletes undoable in History, a specific Pinboard, and Paste Stack entries.
- [ ] Treat one confirmed delete command as one undo batch, including any linked follow-history Stack entries and owned-asset references that must be restored together.
- [ ] V1 does **not** make automatic retention, a remote tombstone, **Clear History**, **Delete All Paste Stacks**, or whole-Pinboard/whole-Stack deletion undoable. Keep those immediate, clearly confirmed privacy/maintenance operations unless a later design explicitly expands the transaction model.
- [ ] If an immediate privacy/maintenance deletion covers an item already in the pending journal, finalize that relevant pending entry immediately, remove its Undo availability, and queue its exact tombstone/cleanup as part of the larger operation.
- [ ] Tell users in destructive confirmation copy whether the operation has five-minute Undo or is immediate and non-undoable.
- [ ] Use normal macOS LIFO semantics: Undo restores the newest still-valid deletion batch. Older batches keep their own original deadlines; a new delete does not extend an older batch.
- [ ] Support both the visible button and native Undo/Cmd-Z when deletion is the current undoable action. Do not let an unrelated text-field Undo trigger item restoration.

### 16B — Persisted soft-deletion journal

- [ ] Reuse Stage 6's exact preflight/ownership and hard-delete transaction rather than creating a second deletion engine. Manual item delete journals first; expiry invokes the existing hard-delete finalizer.
- [ ] Add a local, Pesty-specific pending-deletion journal under `Application Support/Pesty`, written atomically with owner-only directory/file permissions.
- [ ] A `PendingDeletionBatch` records a stable batch ID, concrete `ClipLocation`/container and item IDs, original indices/order, original primary/selection state, record revision, payload snapshot or durable reference, linked cascade members, owned/shared asset references, exact CloudKit record IDs, creation time, and expiry deadline.
- [ ] On delete, preflight the complete batch and ownership graph, then atomically hide/remove it from active local collections and add it to the journal. Do not destroy payloads or assets during the grace period.
- [ ] The grace period is **300 seconds** from the successful local delete transaction—not from confirmation opening, animation completion, or app relaunch.
- [ ] Use a monotonic clock while running and persist a wall-clock deadline for relaunch recovery. Sanity-bound clock changes so rollback cannot extend Undo indefinitely and forward jumps finalize safely.
- [ ] Persist multiple batches independently. Expire/finalize each at its own deadline; when the newest expires or is undone, expose the next still-valid batch if one exists.
- [ ] If the app quits, do not lose the journal. On next launch, restore still-valid Undo batches and finalize already-expired batches before presenting ordinary history UI.
- [ ] Crash recovery must distinguish “still active,” “journaled/hidden,” and “finalized” states idempotently; no record or asset may appear twice or disappear from both active storage and the journal.

### 16C — Undo restoration

- [ ] Undo before the deadline removes the batch from the journal and atomically restores every member to its original concrete container and relative order.
- [ ] Restore the original primary/selection and scroll target when still meaningful; reconcile safely with current search, new captures, reordered Pinboards/Stacks, and deleted containers.
- [ ] Preserve the original record ID and asset ownership when no remote tombstone was sent. Do not mint a duplicate merely to undo a local soft delete.
- [ ] If a newer remote update arrived during the grace period, restore/reconcile the newest valid revision at the original logical location and surface a conflict rather than overwriting it silently.
- [ ] A remote tombstone from another device is authoritative: remove that entry from the local pending batch and do not resurrect it through Undo. Update the visible count; hide the button if the batch becomes empty.
- [ ] If the original container no longer exists, do not recreate it silently. Offer a clear recovery destination or keep the item in a recoverable conflict state until the user chooses.

### 16D — CloudKit and final deletion

- [ ] During the 300-second grace period, emit **no CloudKit tombstone** for a pending local deletion.
- [ ] Document that other devices may continue showing the item during the local five-minute grace period because no remote tombstone exists yet; do not add an unreviewed CloudKit “pending delete” field.
- [ ] Ensure `desiredRecords`/diff logic still treats pending records as remotely desired until expiry, or explicitly suppresses their delete scheduling. Merely removing them from the active UI array must not make sync delete them early.
- [ ] Serialize expiry and Undo through one actor/transaction boundary so a button press cannot race a tombstone handoff.
- [ ] At expiry, first make the batch non-undoable and remove/hide its button, then atomically finalize local deletion and queue the exact CloudKit tombstones.
- [ ] Once a tombstone has been handed to the CloudKit worker, the batch is no longer undoable. A failed CloudKit delete remains a visible/retryable sync operation; it does not restore the local item or extend Undo.
- [ ] When offline, expiry still removes Undo after five minutes and queues tombstones durably. Sync them when connectivity returns.
- [ ] If the app was not running at expiry, make Undo unavailable on the next launch and queue the overdue tombstones during launch recovery. Document that remote deletion cannot occur while the app is not running.
- [ ] Only after finalization may asset cleanup remove a file, and only after proving no active item, Pinboard, Stack entry, pending batch, or other persisted object references it.
- [ ] Preserve Stage 12's follow-history graph: undo restores the linked Stack entries/assets captured in the same batch; expiry deletes them and queues only the exact remote records that are actually syncable.

### 16E — Right-side Undo control

- [ ] Show the control **only** when at least one non-empty, unexpired deletion batch exists.
- [ ] Place it at the trailing/right side of the Paste Bar's top action row—not inside the horizontal card strip—and keep it visible without covering search, Pause, Settings, preview, or Stack controls.
- [ ] Use a native button labeled **Undo Delete**; for a multi-item batch, show a concise count such as **Undo Delete (3)**. A compact countdown may appear when space permits.
- [ ] Keep at least a `28 pt` high native hit target with about `10 pt` horizontal padding. At narrow widths, use the standard undo icon with the full label/count in its tooltip and accessibility label rather than shrinking below a usable target.
- [ ] Expose remaining time in the tooltip/accessibility value and update it without causing the card strip or toolbar to jump every second.
- [ ] At the deadline, remove the control promptly and without stealing focus. With Reduce Motion, change visibility without a motion-heavy transition.
- [ ] If multiple batches exist, the button operates on the newest valid batch; after Undo/expiry it immediately reflects the next batch's count and own remaining time.
- [ ] The control must remain correct while the bar hides/reopens, switches display, resizes, enters search, opens a preview/menu, sleeps/wakes, and processes remote updates.

### 16F — Tests and final release gate

- [ ] Unit-test deadlines at creation, `299.9 s`, `300 s`, after expiry, clock rollback/forward, sleep, quit/relaunch before and after expiry, and multiple overlapping batches.
- [ ] Test single and bulk deletion in every supported container, exact original ordering, selection repair, linked follow-history cascades, shared/missing assets, container disappearance, and a second delete after Undo.
- [ ] Test crash points before/after active-store save, journal save, Undo restore, finalization, asset cleanup, and CloudKit tombstone enqueue; every recovery path is idempotent.
- [ ] In a CloudKit harness, assert zero tombstones before 300 seconds, exact tombstones after expiry, durable offline retry, no early `desiredRecords` diff delete, remote update reconciliation, and remote tombstone invalidation of local Undo.
- [ ] UI-test that the right-side control is absent with no batch, appears after delete, shows the correct count, uses LIFO behavior, survives hide/reopen/relaunch, does not overlap at minimum bar width, and disappears exactly when no batch remains undoable.
- [ ] Test native Cmd-Z scoping in the bar, search, rename, editor, menus, and Settings; text Undo and deletion Undo must not steal each other's responder-chain events.
- [ ] Re-run direct/MAS builds, universal build, complete unit/integration suite, multi-display lifecycle matrix, Clear History privacy tests, Paste Stack cleanup tests, CloudKit retry/convergence tests, and `git diff --check`.
- [ ] Update Settings/help/privacy/release notes to explain the five-minute local grace period, which deletion types qualify, when CloudKit receives tombstones, offline/quit behavior, and what is immediate/non-undoable.
- [ ] Tag/release only after identity, migration, erasure, deletion-Undo, CloudKit, privacy, signing, and full regression gates pass.

**Final exit gate**

- [ ] A deleted item is recoverable, with its order/selection/assets, for the full five-minute window and not afterward.
- [ ] No CloudKit tombstone is emitted during that window; after expiry, exact tombstones are queued durably and retried without resurrecting data.
- [ ] The right-side Undo control appears only while useful, remains accessible and collision-free, and vanishes when no valid batch exists.
- [ ] Immediate privacy/maintenance deletions remain accurately labeled and behave as documented.
- [ ] The final packaged Pesty release passes every prior stage gate plus the new soft-delete/Undo matrix.

---

# Visual and interaction reference index

Screenshots and GIFs in old PRs show product intent; they are **not** approval to restore stale controllers, data models, file permissions, or network behavior. When visual intent and current-main architecture disagree, preserve current-main behavior and recreate the appearance safely.

| Feature | Reference | What to inspect | Guardrail |
|---|---|---|---|
| Current overall bar | [`docs/assets/demo.gif`](docs/assets/demo.gif), [`screenshot-strip.png`](docs/assets/screenshot-strip.png) | Card proportions, bottom-docked bar, rapid keyboard scanning | Re-capture with Pesty branding and current selection/spacing. |
| Live resize | [#5](https://github.com/momenbasel/pesty/pull/5) | Small centered drag affordance and live bar-height feedback | Rebuild on #63/#64; never animate/stage the window below a display. |
| Settings sidebar | [#6](https://github.com/momenbasel/pesty/pull/6) | Native sidebar grouping and pane hierarchy | Preserve every current control and MAS CloudKit section. |
| Local/inline previews | [#8](https://github.com/momenbasel/pesty/pull/8), [#28](https://github.com/momenbasel/pesty/pull/28), [#45](https://github.com/momenbasel/pesty/pull/45) | Content treatment, floating/compact panel, relationship to selected card | Local first, owner-only files, non-key, zero network by default. |
| Paste Stack core/deck | [#9](https://github.com/momenbasel/pesty/pull/9), [#30](https://github.com/momenbasel/pesty/pull/30), [#43](https://github.com/momenbasel/pesty/pull/43), [#55](https://github.com/momenbasel/pesty/pull/55) | Collection, pending/pasted distinction, compact deck, progress | Rebuild identity/privacy/state engine first; do not copy cumulative branches. |
| Source colors/themes | [#10](https://github.com/momenbasel/pesty/pull/10), [#34](https://github.com/momenbasel/pesty/pull/34), [#56](https://github.com/momenbasel/pesty/pull/56) | App-derived header color, theme strength, fallback palette | #56's Default behavior wins; no `#filePath` probe. |
| Pinboard color/rename | [#11](https://github.com/momenbasel/pesty/pull/11), [#54](https://github.com/momenbasel/pesty/pull/54), [#58](https://github.com/momenbasel/pesty/pull/58) | Swatch submenu, inline field, tab reorder | #58 supersedes #11; first keystroke and native responder behavior are acceptance tests. |
| Pause controls | [#12](https://github.com/momenbasel/pesty/pull/12), merged [#39](https://github.com/momenbasel/pesty/pull/39) | Menu label/icon and discoverability | One merged pause state only; ellipsis item is optional polish. |
| Copy feedback | [#13](https://github.com/momenbasel/pesty/pull/13), [#61](https://github.com/momenbasel/pesty/pull/61) | Compact non-key confirmation | Show only after a verified write; preserve true source attribution. |
| Delete Undo | New Pesty Stage 16 requirement | Native trailing **Undo Delete** button, optional batch count/countdown, visible only during the five-minute grace period | Keep it on the right side of the top action row, accessible at narrow widths, and out of the card strip. |
| Liquid Glass | Keep/Revise [#14](https://github.com/momenbasel/pesty/pull/14), reference-only closed [#62](https://github.com/momenbasel/pesty/pull/62) | Material, edge integration, modern appearance | Update #14 last; pin Xcode 26.3 in CI/release, rebase on current main, use top-only corner geometry, one tint, one shadow, and old-OS fallback. |
| Card hierarchy/spacing | Keep/Revise [#15](https://github.com/momenbasel/pesty/pull/15), Keep/Revise [#41](https://github.com/momenbasel/pesty/pull/41), closed [#52](https://github.com/momenbasel/pesty/pull/52) | #15 hierarchy; #41's two padding changes and full-strip images | Land #41 padding in Stage 3; update #15 afterward with split chrome/card palettes, visible inner stroke and `6 pt` ring, no `.scrollClipDisabled()`, and preserved #63/#64. |
| Expanding search | Keep/Revise [#37](https://github.com/momenbasel/pesty/pull/37) | Head truncation and content-driven growth from about `22 pt` to a `700 pt` cap | No GeometryReader/binary jump/ineffective reserve; preserve the clear button's accessibility label. |
| Context actions | Keep/Revise [#42](https://github.com/momenbasel/pesty/pull/42) | Menu grouping/screenshots and destination-aware Paste label; the entire feature remains required | Land key monitor and target first; native main menu and CloudKit-safe mutation precede editing/destructive actions. |

For every visual PR/checkpoint:

- [ ] Capture the same state before and after at 1x and 2x scale where possible.
- [ ] Capture minimum, default, and maximum bar heights.
- [ ] Capture empty, one-card, many-card, first-selected, and last-selected states.
- [ ] Capture long titles/app names, missing icon, high-contrast source color, active search, and multi-selection.
- [ ] Capture normal, dark, Reduce Transparency, Increase Contrast, and macOS 26 Glass/fallback states as available.
- [ ] Capture a vertically stacked display case; that is where stale whole-window animations are especially dangerous.

---

# Pull request outcome ledger

Status is live-audited through 2026-08-10 PDT / 2026-08-11 UTC. **Keep/Revise** means leave the existing open PR open, amend/rewrite it, and rebase it only after its foundations are ready; **blocked** means the current head must not be proposed until its mandatory changes and any named foundation land. “Re-cut” applies only to closed cumulative/stale branches. None of the 15 open heads is merge-ready; all are 13 commits behind `bbce746`. Their timelines contain no formal submitted reviews or inline review threads.

| PR | Audited state/outcome | What survives in this roadmap |
|---:|---|---|
| [#1](https://github.com/momenbasel/pesty/pull/1) | Closed, unmerged; **drop old PR**. Stale fixed right-side preview, superseded by later detached/Quick Look designs. | Preview intent only; use Stages 10–11 and newer #28/#45 references. Do not reopen someone else's stale branch. |
| [#2](https://github.com/momenbasel/pesty/pull/2) | Closed, unmerged; author self-closed a huge draft with unrelated architecture. | Nothing wholesale. Later focused PRs are the source material. |
| [#3](https://github.com/momenbasel/pesty/pull/3) | **Merged.** Stable designated-requirement signing. | Preserve in Pesty identity/signing baseline. |
| [#4](https://github.com/momenbasel/pesty/pull/4) | Closed, unmerged; superseded by later reliable handoff work. | Physical-modifier release and process-target paste in Stage 2 via #49-style implementation. |
| [#5](https://github.com/momenbasel/pesty/pull/5) | Closed for staleness, not merit; maintainer explicitly invited re-cut. | Stage 3 live resize handle on #63/#64. |
| [#6](https://github.com/momenbasel/pesty/pull/6) | Closed, unmerged; sidebar welcomed, old patch deleted MAS CloudKit UI. | Stage 3 focused sidebar preserving all current controls. |
| [#7](https://github.com/momenbasel/pesty/pull/7) | **Merged.** Sync-control gating, later corrected on main. | Preserve current-main MAS/non-MAS gating. |
| [#8](https://github.com/momenbasel/pesty/pull/8) | Closed, unmerged; privacy/security rejection: three silent link requests, no opt-out, weak temp-file permissions, architecture conflicts. | Split Stages 10–11: local Quick Look first; owner-only files; networking default-off. |
| [#9](https://github.com/momenbasel/pesty/pull/9) | Closed, unmerged; large Paste Stack feature conflicts with current hotkey/sync model. | Separate Stages 12–13 after tests/infrastructure; current UUID/privacy redesign. |
| [#10](https://github.com/momenbasel/pesty/pull/10) | Closed, unmerged; superseded by #34/#56 so `SourceColor` lands once. | Stage 4 combined theme design. |
| [#11](https://github.com/momenbasel/pesty/pull/11) | Closed, unmerged; superseded by #58 swatch submenu plus inline rename. | Stage 4 Pinboard-only #58 behavior. |
| [#12](https://github.com/momenbasel/pesty/pull/12) | Closed; mostly superseded by merged #39 pause flag/status icon/shortcut. | Optional ellipsis affordance bound to the existing pause state. |
| [#13](https://github.com/momenbasel/pesty/pull/13) | Closed, unmerged; superseded by CopyResult/provenance/toast direction in #61. | Stage 5, corrected to preserve true source and hide on copy failure without showing success. |
| [#14](https://github.com/momenbasel/pesty/pull/14) | **Open — Keep/Revise; blocked.** Direction accepted; current head fails required toolchain/current-main/visual gates ([comment](https://github.com/momenbasel/pesty/pull/14#issuecomment-5247447945)). | Update existing focused PR last: Xcode 26.3 CI/release, current-main rebase, correct corners, one tint/shadow, old-OS QA. |
| [#15](https://github.com/momenbasel/pesty/pull/15) | **Open — Keep/Revise; blocked on #41.** Card-body direction accepted; shared palette causes Dark Mode contrast failure ([comment](https://github.com/momenbasel/pesty/pull/15#issuecomment-5247494659)). | Land #41 spacing first; split chrome/card tokens, strengthen inner stroke, remove `.scrollClipDisabled()`, and rebase. |
| [#16](https://github.com/momenbasel/pesty/pull/16) | **Open — Keep/Revise; blocked on tests.** Feature/provider shape accepted; timed dismissal rejected ([comment](https://github.com/momenbasel/pesty/pull/16#issuecomment-5247489680)). | Update after Stage 1; use #59 as tests/reference without replacing #16. |
| [#17](https://github.com/momenbasel/pesty/pull/17) | **Open — Keep/Revise; blocked.** Read path wanted; hardcoded origin/untrusted marker/pairing/exclusion issues block merge ([comment](https://github.com/momenbasel/pesty/pull/17#issuecomment-5247499190)). | Correct/rebase #17 as Stage 5 attribution only; #61 remains separate `CopyResult`/toast reference. |
| [#18](https://github.com/momenbasel/pesty/pull/18) | **Open — Keep/Revise; blocked on trigger rewrite/tests.** Bug confirmed; selected-ID trigger usually does not fire and can poison the next selection ([comment](https://github.com/momenbasel/pesty/pull/18#issuecomment-5247495036)). | Early candidate after foundations: presentation token/scroll state, preserved inset, same-ID/rapid-reopen tests. |
| [#19](https://github.com/momenbasel/pesty/pull/19) | **Open — Keep/Revise; blocked on repeat-safe exact deletion.** Intent wanted; repeat/current delete semantics unsafe ([comment](https://github.com/momenbasel/pesty/pull/19#issuecomment-5247448060)). | Maintainer minimum: repeat guard; also add cooldown, adjacent selection, container scope, docs/tests. Pesty's stricter local release policy adds Stage 16 Undo. Not superseded by #57. |
| [#20](https://github.com/momenbasel/pesty/pull/20) | **Open — Keep/Revise; blocked on #42 infrastructure.** Idea accepted; default chord broken by character parsing ([comment](https://github.com/momenbasel/pesty/pull/20#issuecomment-5247494782)). | KeyCode digits, distinct modifier choices, useful file/plain-text semantics, raw flags, and layout tests. |
| [#21](https://github.com/momenbasel/pesty/pull/21) | **Open — Keep/Revise; blocked on retention/sync redesign.** Current-main compile failure plus unsafe cross-device CloudKit deletion semantics ([comment](https://github.com/momenbasel/pesty/pull/21#issuecomment-5247449956)). | Keep open and rewrite after choosing the sync contract; preserve validated migration intent, apply-on-release confirmation, bounded `Forever`, and two-device tests. |
| [#22](https://github.com/momenbasel/pesty/pull/22) | **Open — Keep open; blocked on #42.** Guard/default correct alone; stale destination, escape/panel/trigger semantics make it unsafe ([comment](https://github.com/momenbasel/pesty/pull/22#issuecomment-5247494930)). | After #42 `pasteTarget`: update destination on app switch, guarantee dismissal, define level/Cmd-Tab/Settings behavior, preserve #64 and suppression. |
| [#23](https://github.com/momenbasel/pesty/pull/23) | **Merged.** Menu-bar visibility preference; later main hardened recovery. | Preserve current behavior; no reopen. |
| [#24](https://github.com/momenbasel/pesty/pull/24) | Closed, mostly superseded by issue #64. Its unconditional resign-active path breaks suppression during rename. | Only the explicitly identified hide→show cancellation race in Stage 2. |
| [#25](https://github.com/momenbasel/pesty/pull/25) | **Merged.** Quit action. | Preserve; no reopen. |
| [#26](https://github.com/momenbasel/pesty/pull/26) | Closed, unmerged; **drop**. Maintainer screenshots were byte-identical with/without explicit switch style. | Keep native Form toggles. Revisit only with a reproduced OS-version bug and screenshot. |
| [#27](https://github.com/momenbasel/pesty/pull/27) | **Merged.** Excluded-app privacy; main added sync/source/sandbox fixes. | Preserve validated declared-source exclusions in Stage 5. |
| [#28](https://github.com/momenbasel/pesty/pull/28) | Closed, unmerged; huge stacked floating-preview branch. Link metadata must be default-off. | Stages 10–11, split native Quick Look, detached panel, and networking. |
| [#29](https://github.com/momenbasel/pesty/pull/29) | Closed, unmerged; depends on absent Paste Stack core and carries its parent stack. | Stage 13 entry preview only after redesigned core. |
| [#30](https://github.com/momenbasel/pesty/pull/30) | Closed, unmerged; deck workflow too large and stacked. | Stage 13 compact/full workflow split into tested components. |
| [#31](https://github.com/momenbasel/pesty/pull/31) | Closed, unmerged; small active-app paste/save layer depends on old shared UUID semantics. | Stage 13 paste/save after per-container identity redesign. |
| [#32](https://github.com/momenbasel/pesty/pull/32) | Closed, unmerged; 26 stacked commits and about 720 changed Settings lines. Conditional, not specifically requested in re-cut list. | Split by pane in Stage 3 or park; never reopen wholesale. |
| [#33](https://github.com/momenbasel/pesty/pull/33) | Closed, unmerged; stack persistence assumes shared UUIDs and unsafe Clear History behavior. | Stage 12 explicit identity, privacy default true, independent assets. |
| [#34](https://github.com/momenbasel/pesty/pull/34) | Closed, unmerged; one of the strongest small feature candidates, but old icon probe is unsafe. | Stage 4 combined with #56; remove `#filePath` probe. |
| [#35](https://github.com/momenbasel/pesty/pull/35) | Closed, unmerged; tiny unique preference carried a 27-commit stack and was not in preferred early list. | Optional Stage 3 selection-position setting after navigation settles. |
| [#36](https://github.com/momenbasel/pesty/pull/36) | **Open — Keep/Revise.** Broad screenshot relaxation rejected; maintainer supplied a narrow mergeable no-visual-delta exception ([comment](https://github.com/momenbasel/pesty/pull/36#issuecomment-5247499565)). | Amend in place: visual changes keep before/after full-strip images; explicitly state when there is no visual delta. Independent documentation work. |
| [#37](https://github.com/momenbasel/pesty/pull/37) | **Open — Keep/Revise.** Head truncation approved; binary width jump rejected ([comment](https://github.com/momenbasel/pesty/pull/37#issuecomment-5247499441)). | Stage 2E ideal-width growth capped at `700 pt`; remove GeometryReader/reserve/container label; preserve sync gating. |
| [#38](https://github.com/momenbasel/pesty/pull/38) | **Open — Keep/Revise; blocked on launch-source redesign.** Reopen wanted; onboarding removal and unconditional delayed presentation after every launch rejected ([comment](https://github.com/momenbasel/pesty/pull/38#issuecomment-5247489562)). | Keep open; preserve onboarding, use the one current handler/`isPresented`, show only for explicit foreground launches/reopens, and stay hidden for login/background launch. Foreground-launch behavior needs upstream approval. |
| [#39](https://github.com/momenbasel/pesty/pull/39) | **Merged.** Paste Bar settings/pause shortcut work. | Preserve as the one pause state; optional UI polish only. |
| [#40](https://github.com/momenbasel/pesty/pull/40) | **Open — Keep/Revise; blocked on deletion/selection redesign.** Scoped deletion/image cleanup and multi-select remain required; current modifier, confirmation, identity, selection, and sync behavior blocks merge ([comment](https://github.com/momenbasel/pesty/pull/40#issuecomment-5247489406)). | Keep open; implement exact deletion first, then rebuild selection in Stage 8. Do not cherry-pick the structurally dependent delete commit alone. |
| [#41](https://github.com/momenbasel/pesty/pull/41) | **Open — Keep/Revise.** Padding wanted; alignment commit measured as a no-op ([comment](https://github.com/momenbasel/pesty/pull/41#issuecomment-5247499323)). | Stage 3 top `4→16`, bottom `18→26`, `300 pt` QA, and spacing-oriented title; Stage 14 only revalidates. |
| [#42](https://github.com/momenbasel/pesty/pull/42) | **Open — Keep/Revise; blocked on foundations/safe mutation.** Key-monitor, `pasteTarget`, editor, and context features remain required; current combined branch has data-loss/native-menu blockers ([comment](https://github.com/momenbasel/pesty/pull/42#issuecomment-5247489252)). | Keep open; land Stage 2 foundations and main menu first, then rebuild Stage 7 mutation/context work in small safe slices. |
| [#43](https://github.com/momenbasel/pesty/pull/43) | Closed, unmerged; tiny unique move-to-stack change carried a huge stack. | Stage 13 **Add to** Stack after core; use accurate wording. |
| [#44](https://github.com/momenbasel/pesty/pull/44) | Closed, unmerged; reorder follows absent core. | Stage 13 pending-before-pasted reorder with state tests/shared components. |
| [#45](https://github.com/momenbasel/pesty/pull/45) | Closed, unmerged; enormous stack around a compact preview delta. | Stages 10–11; split local non-key panel from link networking. |
| [#46](https://github.com/momenbasel/pesty/pull/46) | Closed; **superseded as standalone**. Tiny non-key/no-duplicate-shadow fix. | Fold directly into Stage 10 detached preview. |
| [#47](https://github.com/momenbasel/pesty/pull/47) | Closed, unmerged; external-open delta useful but no temp cleanup. | Stage 10 explicit external open with bounded cleanup/tests. |
| [#48](https://github.com/momenbasel/pesty/pull/48) | Closed; **superseded as standalone**. Seven-line delete menu absorbed by later deck/core. | Fold into Stage 13; no independent PR. |
| [#49](https://github.com/momenbasel/pesty/pull/49) | Closed, unmerged; high-value reliability ideas in a 73-commit stack; old controller superseded by #63/#64. | Stage 2/5 small slices: stable scroll, direct handoff, copy promotion, and nonduplicative race residue. Use #42—not #49—as the source of truth for `pasteTarget`; never carry the old controller. |
| [#50](https://github.com/momenbasel/pesty/pull/50) | Closed, unmerged; best first candidate but stacked on absent #48. | Stage 1 test-target infrastructure only; port Stack tests later. |
| [#51](https://github.com/momenbasel/pesty/pull/51) | Closed, unmerged; configurable native opener depends on preview stack and is over 400 unique lines. | Stage 10 after preview base; split opener from Settings. |
| [#52](https://github.com/momenbasel/pesty/pull/52) | Closed; controller/motion superseded by #63/#64. | At most extract card inset/spacing residue in Stage 14. |
| [#53](https://github.com/momenbasel/pesty/pull/53) | Closed, unmerged; active-stack search depends on absent core. | Stage 13 search projection, order preservation, selection repair, no-results state. |
| [#54](https://github.com/momenbasel/pesty/pull/54) | Closed, unmerged; strong candidate, but mix includes Stack navigation and incorrect modulo grouping. | Stage 4 Pinboard reorder first; defer Stack section navigation. |
| [#55](https://github.com/momenbasel/pesty/pull/55) | Closed, unmerged; central 77-commit Stack branch with conflicts, hidden compile issue, shared-UUID mismatch, and privacy bug. | Stages 12–13 only. Its close comment defines the one-PR/~300-line/test-first plan. |
| [#56](https://github.com/momenbasel/pesty/pull/56) | Closed, unmerged; small correction that preserves source-derived Default and stabilizes other themes. | Fold into #34's Stage 4 re-cut from day one. |
| [#57](https://github.com/momenbasel/pesty/pull/57) | Closed; **superseded as standalone**. Tiny Backspace bulk-delete rule depends on unfinished multi-select. | Stage 8 acceptance criterion after deletion/selection redesign. |
| [#58](https://github.com/momenbasel/pesty/pull/58) | Closed, unmerged; Pinboard half explicitly invited, pause half mostly superseded by #39. | Stage 4 inline rename/swatches; optional single-state pause affordance. |
| [#59](https://github.com/momenbasel/pesty/pull/59) | Closed, unmerged; cleanest old drag code/tests, but lifecycle and representations incomplete. | Stage 9 after fixing drag end, multi-file, URL, color, lazy image, naming. |
| [#60](https://github.com/momenbasel/pesty/pull/60) | Closed, unmerged; reopen handler wanted, delayed presentation after normal launch rejected. | Stage 2 one reopen handler; no Launch-at-Login focus theft. |
| [#61](https://github.com/momenbasel/pesty/pull/61) | Closed, unmerged; wanted CopyResult/toast direction, still hardcoded source and lacked validation/failure semantics. | Stage 5 split validated provenance from success-only toast. |
| [#62](https://github.com/momenbasel/pesty/pull/62) | Closed, unmerged; Liquid Glass follow-up still missed Xcode workflows/docs, corner/tint/shadow requirements. | Conditional Stage 14 after pinned Xcode 26.3/toolchain approval. |
| [#63](https://github.com/momenbasel/pesty/pull/63) | **Merged.** Multi-display bar placement/content animation fix. | Restore and preserve in Stage 0 and every UI stage. |

### Related issue, not a PR

| Issue | Outcome | Required carry-forward |
|---:|---|---|
| [#64](https://github.com/momenbasel/pesty/issues/64) | Closed/completed and released in 1.2.0. Replaced fragile show/hide flags with phase, epoch, completion backstop, recovery, and hotkey retry. | This is architecture, not optional polish. Reopen only for a newly reproduced regression; all feature work must integrate with it. |

### Quick outcome summary

- **Already merged/no reimplementation:** #3, #7, #23, #25, #27, #39, #63, plus issue #64.
- **All open PRs stay open and must ultimately be implemented.** #21, #38, #40, and #42 require substantial revision; they are blocked, not rejected or abandoned. #22 stays blocked on #42 `pasteTarget`.
- **Merge an existing open head as-is:** none.
- **Drop or never revive independently:** #1, #2, #4, #10, #11, #12, #13, #26, #46, #48, #52, #57.
- **Best early focused work:** independent #36 wording; #50 test target; #42 key-monitor and `pasteTarget` foundations; minimal native main menu; revised #38 launch/reopen behavior; revised #18, #20, #37, #22, and #41; revised #17; then #40 scoped-delete foundation, #24's tiny race, #5, #6, #34+#56, #54, and #58 Pinboard-only.
- **Medium/high-risk work after foundations:** update open #16 using #59 tests/reference; finish revised #21 retention; finish Stage 7 editor/context in #42; finish Stage 8 multi-select in #40; #14 last among visual/open feature work after toolchain approval; final Stage 16 Undo and #19 integration remain the release-ending step by Pesty policy.
- **Previews last and split:** #8, #28, #45+#46, #47, #51; link networking remains separate/default-off.
- **Paste Stack as the 2.1.0 feature release:** #9, #29–#31, #33, #43–#44, #48, #53, #55.
- **Conditional/ask before investing:** #32, #35, #62 and optional duplicated pause/visual residue.

## Optional maintainer-coordination comment for the fork maintainer to post

Do not post this automatically. If the fork maintainer wants upstream prioritization after preserving the fork, one concise comment is better than reopening old PRs individually:

> Thanks for the detailed review. I plan to keep every live PR open and implement all of the requested features, while revising each current head to address its review blockers. I will not propose any existing head as-is. After the #50 test-target foundation, my proposed order begins with #42 key-monitor scoping, #42 reliable `pasteTarget`, the minimal native main menu, then revised #38 launch/reopen behavior: onboarding stays, login/background startup remains hidden, and only an explicit foreground launch or reopen may show the bar. I understand the reopen part is accepted while foreground-launch presentation needs re-discussion. #40 deletion/multi-select, #21 retention, and #42 full context editing all remain required after their foundations, and Pesty's five-minute Undo remains the final release gate. Does that dependency order match what you would most like reviewed?

Before posting, update the list for anything that has since merged or changed. Post only under the fork maintainer's account and only with the fork maintainer's explicit confirmation.

---

# Manual QA matrices

Automated tests are necessary but cannot prove window focus, cross-display animation, TCC identity, native drag/drop, or visual accessibility. Record OS, hardware, build mode, display layout, and result for every manual run.

## Displays and bar lifecycle

| Case | Required checks |
|---|---|
| One display | Pointer targeting, bottom alignment, min/default/max height, show/hide, resize, search, preview, toast. |
| Horizontal displays | Pointer near each edge/gap; bar never crosses or stages on another display. |
| Vertically stacked displays | Show/hide and interrupted animation never travel through the neighboring display; preview/tray stay in visible frame. |
| Mixed scale/portrait | Correct coordinate conversion, focus ring sharpness, resize delta, preview pointer, edge insets. |
| Dock/menu changes | Visible-frame recalculation, forced hide/reopen, no stale frame. |
| Sleep/wake/display attach | `forceHide`, panel recovery, hotkey retry, no resurrected preview/toast/tray. |
| Rapid interruption | Hotkey/show/hide/reopen/resize at least ten times; no stale completion or duplicate panel. |
| Persistent-bar preference (#22) | Safari→open bar→Notes targets Notes; Cmd-Tab, Pesty Settings, full-screen Spaces, hidden menu icon, global-hotkey dismissal, MAS and direct paths. |

## Input, focus, and accessibility

| Case | Required checks |
|---|---|
| Search | First character, spaces, held/repeating Backspace through the final query character, post-search cooldown, Escape, content-driven expansion/collapse, IME/composition, clear-button accessibility, no shortcut theft. |
| Rename/editor | Standard menu commands, Undo/Redo, Return rules, Cmd-Return save, Escape cancel, field-editor focus. |
| Navigation | Arrows, Home/End if supported, first/last ring visibility, primary selection, source changes. |
| Quick paste (#20) | KeyCode 1–9, Shift punctuation, non-US layout, every allowed modifier, conflicting pickers, rich/plain/file payloads. |
| Multi-select | Normal/Cmd/Shift click, keyboard selection, filter changes, incoming clip, confirmation wording. |
| Menus/alerts | Bar monitor does not consume events; action remains scoped to clicked item and current target. |
| VoiceOver | Names, roles, selected/primary state, counts, reorder alternatives, resize help, destructive warning. |
| Accessibility settings | Increase Contrast, Reduce Transparency, Reduce Motion, keyboard-only operation. |

## Payload, storage, and privacy

| Case | Required checks |
|---|---|
| Text/RTF | Unicode, very long text, empty text, invalid RTF, plain-text override, edit/copy/drag/preview. |
| Links | Valid HTTP(S), invalid URL, credentials, local/private targets, offline, network setting off/on. |
| Colors | Valid/invalid hex, native color drag, readable theme contrast. |
| Images | Large image, missing PNG, shared legacy filename, lazy drag, preview temp permissions/cleanup. |
| Files | One/multiple files, stale URL, missing file, collision names, external open, sandbox behavior, useful non-lossy plain-text representation rather than bare filenames. |
| Provenance | Valid installed/uninstalled bundle, malformed/oversized marker, excluded declared source, self-copy suppression. |
| Retention/delete | Count/age, slider release/confirmation, mode switch without deletion, `Forever` bounds, returning offline device, different device policies, zero unintended retention tombstones, exact container delete, referenced asset, Clear History. |
| Five-minute Undo | Single/bulk delete, 299.9/300-second boundary, multiple batches, hide/reopen/relaunch, offline expiry, exact CloudKit tombstones, remote update/delete, assets, and right-side button layout. |
| Paste Stack | follow-history true/false, delete all, clone ownership, relaunch, corrupt store, selection repair. |
| Network privacy | Packet/mock assertion of zero default requests; bounded opt-in fetch and cancellation. |

## Build, identity, and sync

| Case | Required checks |
|---|---|
| Direct build | Universal binary, correct Info/signing identity, Accessibility paste granted/denied/revoked. |
| MAS conditional | Compiles without forbidden symbols; correct CloudKit UI; no upstream Team/profile assumptions. |
| Pesty coexistence | Separate app/defaults/storage/temp/Login Item/TCC rows; distinct default hotkeys; shared pasteboard documented. |
| iOS simulator/device | Renamed host/module/tests; entitlement; offline/online sync if implemented; physical provisioning separately verified. |
| Two-device sync | Insert/update/explicit-delete/conflict/image/order convergence; no shared-ID collision; schema compatibility; local retention on one device never silently becomes account-wide deletion. |
| Fresh/upgrade/corrupt | Empty install, upgrade defaults, bad JSON/default, missing assets, interrupted atomic write, full erase. |

---

# Slice sizing and definition of done

## How to size implementation slices

- Aim for one behavior and one reason to change per slice.
- About 300 changed production lines is a reviewability target, not a loophole: generated files, unrelated formatting, and copied parent commits make a slice larger even if the feature commit is small.
- Split state engine/persistence from UI. Split local behavior from networking. Split non-destructive actions from mutations. Split infrastructure from dependent features.
- Keep tests with the behavior they prove; do not move all tests to a final cleanup PR.
- If a slice approaches 500 production lines or changes more than roughly 5–7 core files, stop and look for a stable seam.
- Avoid stacked branches containing parent feature commits. Start each independent slice from the integrated current base.
- A visual-only slice must not silently change persistence, hotkeys, window lifecycle, networking, or clipboard semantics.
- A schema or migration slice must not also introduce a large user interface.

## Definition of done for every stage/slice

- [ ] The dependency stage is complete and its tests are green.
- [ ] The implementation follows current-main #63/#64, per-container UUID, sync, and MAS/direct boundaries.
- [ ] Pesty identity and storage isolation remain intact.
- [ ] Unit/integration tests cover the happy path, cancellation/failure, migration, and the specific bug that motivated the work.
- [ ] `swift test`, `swift build`, `swift build -Xswiftc -DMAS`, and `git diff --check` pass.
- [ ] UI work has before/after Debug Demo evidence using the sizing and visual matrix.
- [ ] Focus, keyboard, VoiceOver, Reduced Motion/Transparency, and small-display behavior are checked where relevant.
- [ ] Privacy/security review covers pasteboard validation, files/permissions, deletion ownership, logging, and network behavior.
- [ ] Documentation/help/privacy/release notes match the actual behavior.
- [ ] No unrelated changes, stale cumulative commits, generated secrets, upstream signing identity, or local absolute paths are included.
- [ ] The working tree and any checkpoint/commit are shown clearly to the fork maintainer; no GitHub write occurs without explicit approval.

## First instruction for the next coding agent

Start with **Stage 0 only**. Inspect the live repository again, report anything that changed since this audit, and propose the exact recoverable checkpoint plus clean-current-main integration method. Do not begin feature implementation, comment on a PR, or normalize the dirty tree until the fork maintainer approves that preservation step.
