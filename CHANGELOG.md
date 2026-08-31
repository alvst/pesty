# Changelog

All notable changes to Pesty-Alvie are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Pesty-Alvie uses separate release trains for the Mac app and its later
companions:

- **2.0.0** is the next macOS release. It does not include Paste Stacks or any
  iPhone/iPad target.
- **2.1.0** is the planned macOS Paste Stacks release, following the upstream
  tracker for that feature.
- **2.5.0** is the planned iPhone/iPad companion release. The iOS app, widget,
  share extension, and private-CloudKit synchronization between Mac and iOS all
  belong to 2.5.0, not 2.0.0 or 2.1.0.

### Planned for 2.0.0 (macOS)

#### Added
- Added Mac-only JavaScript extensions for bounded multi-hook clip-card
  decorations, weighted and type-filtered derived categories, and explicit
  plain-text transform paste actions, including typed manifest-declared
  configuration with persisted inline controls and cache-safe `config`
  injection, user-invoked safe menu actions for transformed copying and Finder
  reveal, capability chips, strict execution limits, persistent auto-disable
  after quarantine, an in-memory result cache, and bundled Token Count and JSON
  Detector examples.

#### Changed
- Renamed the personal fork's app, executable, bundle, icon, packaging, and
  documentation identity to Pesty-Alvie.
- Separated preferences, local and iCloud Drive storage, preview temp folders,
  pasteboard source attribution, login-item identity, Accessibility identity,
  and default global shortcuts from upstream Pesty.

### Planned for 2.1.0 (macOS)

#### Added
- Paste Stacks, delivered as a separate feature release in line with the
  upstream tracker rather than folded into the 2.0.0 release.

### Planned for 2.5.0 (iPhone and iPad)

#### Changed
- Renamed the iOS companion product and project to Pesty-Alvie with separate
  app, test, and CloudKit identifiers.

#### Added
- Added live private-CloudKit sync between the sandboxed Mac build and the
  iPhone/iPad companion, including offline work, images/RTF assets, Pinboard
  order, conflicts, per-container IDs, and delayed hard deletes for Undo.
- Added local image creation/copying on iOS, owner-protected asset storage,
  CloudKit status UI, device provisioning guidance, and Mac/iOS sync tests.
- Added the iOS widget and share extension; both ship on the 2.5.0 train with
  the companion rather than with macOS 2.0.0.

The entries below describe the inherited upstream Pesty release history.

## [1.1.0] - 2026-06-26

Visual overhaul to match Paste, plus iCloud sync.

### Added
- iCloud Drive sync (opt-in) for history and pinboards across your Macs.
- Live Accessibility permission status in Settings, with a Restart button.

### Changed
- Redesigned cards: per-source-app colored header band, app-icon tile, type
  label, verbose relative time, and a footer with character count + quick-paste
  number — a faithful match to Paste.
- Spring animations for selection, hover, and scrolling; taller default strip.
- Top bar now has a sync toggle, search indicator, a "Clipboard" tab, and a
  "…" overflow menu.

### Fixed
- Search input and keyboard navigation reliability.
- Removed the unnecessary Apple Events entitlement.

[1.1.0]: https://github.com/momenbasel/pesty/releases/tag/v1.1.0

## [1.0.0] - 2026-06-26

Initial public release.

### Added
- Slide-up clipboard strip with a global hotkey (default `⌘⇧V`).
- Color-coded cards for text, rich text, links, images, files, and colors, each
  showing source app, editable title, copy time, preview, and character count.
- Pinboards: named, color-tagged collections of saved clips.
- Instant search across the full history.
- Keyboard navigation: arrows to move, `return` to paste, `⌘1`–`⌘9` quick-paste,
  `⌘⌫` to delete, `esc` to close.
- Direct paste into the previously active app via synthesized `⌘V`.
- Privacy: ignores concealed (password-manager) clips.
- Menu-bar item, preferences window, configurable hotkey, launch at login.
- Universal binary (Apple Silicon + Intel), signed with Developer ID and
  notarized by Apple.

[1.0.0]: https://github.com/momenbasel/pesty/releases/tag/v1.0.0
