# Feasibility: a user-installable extension system for Pesty

An assessment of what it would take to build the extension system proposed in #81 — specifically the full version, where users install third-party extensions (e.g. a token-counting extension with per-model tokenizer profiles), rather than toggling built-in modules.

**Short version: the hard part is distribution and security, not code.** The Mac App Store build makes loading foreign code essentially a non-starter, so the design space narrows to sandboxed script hosting or a declarative rules format — and either way, handing clipboard contents to third-party code needs a permissions model before it needs an API.

## The distribution wall

Pesty ships in three Mac configurations, and the constraints come from the strictest one:

| Build | Sandbox | Consequence |
|---|---|---|
| Direct/DMG (`swift build` + script-assembled bundle) | No, but hardened-runtime signed + notarized | Library validation blocks unsigned plugin dylibs |
| Mac App Store (`-DMAS`) | Yes, hardened runtime | No dylib loading, no subprocesses, no downloaded native code |
| Xcode Mac target | Yes (CloudKit dev) | Same as MAS |

That rules out the classic plugin architectures outright:

- **Native plugins (dylib/bundle loading)** — dead on arrival for MAS, and blocked by library validation on the notarized direct build unless signing requirements are loosened.
- **`NSExtension`/`.appex`-style extensions** — technically MAS-legal, but Pesty's Mac targets have no App Group to share data through, and the direct build is assembled by `swift build` plus a shell script, which cannot produce `.appex` bundles. This route forks the build story into Xcode-only.
- **Subprocess/CLI extensions** (the Raycast script-command model) — blocked by App Sandbox in the MAS build.

What survives:

1. **JavaScriptCore-hosted extensions.** JSC is a system framework (keeps the zero-dependency rule), works under App Sandbox, and downloading *interpreted* scripts is permitted by App Review under 2.5.2/3.3.1B-style rules as long as they can't change the app's core behavior — a line that an extension system deliberately walks up to, so review risk is real. All extension logic runs in-process; a runaway or malicious script is Pesty's problem.
2. **A declarative format** (JSON/regex rules: detectors, badges, transforms). Zero code execution, zero review risk, trivially safe — but it can't express a tokenizer with per-model profiles, which is the motivating use case in #81. Useful as a first rung, not the destination.

## The security problem is bigger than the engineering problem

A clipboard manager's entire data set is sensitive by definition — passwords that slipped past concealed-clip filtering, tokens, private text. Handing that to third-party code directly undercuts Pesty's stated privacy posture ("no API calls, no clipboard uploads"), and the MAS build already holds the `com.apple.security.network.client` entitlement for CloudKit — so any extension with both clip access and reachable network APIs is an exfiltration vector.

A credible Tier 3 design therefore needs, before any extension runs:

- **No network or filesystem surface exposed to extensions at all** (the token-counting case needs pure computation only — start there and never widen by default);
- **Per-extension grants** for what an extension may read (text of the current card vs. full history) — with concealed clips excluded at the host boundary, not by extension politeness;
- **Resource limits** — a wall-clock budget and cancellation for scripts, since JSC runs in-process and everything in Pesty today is `@MainActor`;
- **A trust/signing story** for distribution (even just "extensions are gists you paste in at your own risk" is a stance that must be chosen and documented).

## What the codebase gives you today: almost nothing to hang it on

- **No registry pattern exists anywhere.** There is not a single multi-conformer protocol in the Mac app; detectors (hex color, links) are hardcoded `if`-chains in `ClipboardMonitor.makeItem()`. The internal hook points (capture-time, card metadata, transforms) all have to be built first — an extension host is the *second* project, sitting on top of that refactor.
- **`ClipItem` is a fixed struct with no metadata bag.** Extension output must live in a sidecar store keyed by clip UUID; writing into the item bumps `updatedAt` (CloudKit conflict resolution) and pollutes `store.json` and the sync schema, which CI enforces as byte-identical between Mac and iOS.
- **Everything is `@MainActor`, with strict concurrency checking off** (`swiftLanguageModes: [.v5]`). Running extension work off-main is the codebase's first real concurrency boundary, and the compiler won't catch the mistakes.
- **iOS doubles everything.** There is no shared module — models and converters are hand-duplicated pairs — and iOS cards show no metadata labels today. A cross-platform extension story is a second implementation, or extensions stay Mac-only (probably the right call initially).

## Likely bugs, ordered by likelihood

1. **Script-induced main-thread hangs** — a slow or looping extension script freezes the strip unless every invocation is off-main with a hard timeout from day one.
2. **Data races** — JSC contexts and result caches crossing the main-actor boundary with concurrency checking disabled; intermittent crashes rather than compile errors.
3. **Sync pollution** — extension data creeping into `ClipItem`/CloudKit, causing spurious sync writes and dedup confusion.
4. **Stale results on recycled cards** — cards live in a `LazyHStack`; async extension output racing scroll flashes the wrong card's badge.
5. **Review-time surprises** — App Review rejecting or stalling the MAS build over downloadable scripts; needs a fallback plan (bundled-only extensions on MAS).
6. **Cache/context leaks** — per-clip result caches and JSC contexts with no eviction wired to clip deletion or extension uninstall.
7. **`#if MAS` behavior drift** — the extension host inevitably behaves differently across the three build configs; CI catches compile breaks, not behavior.
8. **Version skew** — extensions written against API v1 breaking on app updates; an extension system is a permanent compatibility contract, not a feature.

## Rough shape and cost

A minimal but honest Tier 3 — JSC host, one hook point (card metadata/badge), pure-compute API, per-extension enable toggles, timeout + cancellation, sidecar result store, an Extensions settings pane (which would be the first dynamic content in Settings) — is a **multi-week project**, on top of the internal-API refactor it presupposes. The token-counting extension itself is then small: the estimator is pure computation and fits the exposed API exactly, which is what makes it the right first extension — it exercises the host without demanding network, storage, or UI surface.

The permanent costs are the part to weigh: an API compatibility contract, a security boundary to maintain, App Review exposure, and support burden for third-party code misbehaving inside Pesty's process.

---

*Grounded in the Pesty fork, which compiles the same `Sources/Pesty` tree as the upstream Mac target; upstream should be structurally similar. Written August 2026.*
