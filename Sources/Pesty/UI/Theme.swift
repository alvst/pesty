import AppKit
import SwiftUI

enum Theme {
    static let cardWidth: CGFloat = 215
    // Leave room for the selected card's focus ring and shadow so adjacent
    // clips never visually run into it.
    static let cardSpacing: CGFloat = 28
    // Inset the scrollable content without shrinking its clipping bounds, so
    // the selected-card ring and shadow remain intact at either side.
    static let cardStripViewportInset: CGFloat = 20
    // Each scroll target is wider than its visible card. `scrollTo` therefore
    // keeps the ring clear of the viewport edge instead of aligning the card
    // flush against it. The stack spacing compensates so visible cards still
    // retain the normal 28 pt gap.
    static let cardScrollTargetPadding: CGFloat = 20
    static let cardStripLayoutSpacing: CGFloat = cardSpacing - cardScrollTargetPadding * 2
    // The extra buffer at the actual start and end of the scrollable content.
    // Together with the viewport inset, this leaves 43 pt around a selected
    // card's visible focus ring at either end of the strip.
    static let cardStripEdgeInset: CGFloat = 29
    static let cardStripStartTargetWidth: CGFloat = cardStripEdgeInset
        - cardScrollTargetPadding
        - cardStripLayoutSpacing
    static let cardStripEndContentInset: CGFloat = cardStripEdgeInset - cardScrollTargetPadding
    static let cardStripTopInset: CGFloat = 16
    static let cardStripBottomInset: CGFloat = 26
    static let cornerRadius: CGFloat = 16
    // A softer card shape lets the selected blue outline read as an intentional
    // focus ring instead of a tight rectangle around the current clip.
    static let cardCorner: CGFloat = 19
    static let headerHeight: CGFloat = 68
    // Enlarged-icon mode: the source icon is scaled well past the header and
    // cropped by the card's own top-right corner. Every app gets the same
    // size and overhang, so the crop reads as deliberate framing rather than
    // as each icon being clipped differently. The header is also tighter
    // here than the tile layout needs — a roomy header is what makes a large
    // icon read as undersized.
    // The header is sized around the icon rather than the icon being blown up
    // to fill the header: scaling artwork past its natural size is what makes
    // it look soft.
    static let enlargedHeaderHeight: CGFloat = 50
    static let enlargedIconSize: CGFloat = 62
    static let enlargedIconOverhang: CGFloat = 12
    // How far the artwork's bottom hangs past the header seam onto the clip
    // content. The icon is drawn from trimmed artwork, so this is a true edge
    // offset rather than a guess at the icon's built-in transparent padding.
    static let enlargedIconDrop: CGFloat = 5
    /// File cards lean on the document icon to say what the clip is, so it is
    /// sized as the card's subject rather than as a small adornment.
    static let fileIconSize: CGFloat = 104
    static let enlargedIconRise: CGFloat = enlargedIconSize - enlargedHeaderHeight - enlargedIconDrop

    static let cardBody = Color.white.opacity(0.94)
    static let cardBorder = Color.black.opacity(0.12)
    // The focus color needs to remain unmistakable against both bright and
    // saturated clip headers. Use the system's vivid blue rather than a muted
    // tint so keyboard navigation is effortless to follow.
    static let selection = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let selectedCardRing: CGFloat = 6

    // MARK: - Card ink
    //
    // A clip card is an opaque near-white surface (`cardBody`) no matter what
    // the appearance is, so its text stays fixed dark. These are deliberately
    // *not* appearance-aware — flipping them would make cards unreadable.

    static let textPrimary = Color.black.opacity(0.82)
    static let textSecondary = Color.black.opacity(0.52)
    static let textTertiary = Color.black.opacity(0.34)

    static let headerText = Color.white
    static let headerSubText = Color.white.opacity(0.78)

    // MARK: - Chrome ink
    //
    // The Paste Bar is glass over whatever the user happens to have on screen,
    // so unlike a card it has no fixed brightness to design against. Every
    // color below is resolved per-appearance and, where it's text, *measured*
    // against the fill it lands on rather than assumed — see `Contrast`. The
    // previous single hard-coded palette assumed a dark backdrop, which left
    // white pill labels at 1.27:1 over a light desktop.

    /// One appearance's worth of chrome: the fills Pesty paints, plus the
    /// opaque color it assumes the glass is sitting on. `backdrop` is an
    /// estimate — macOS exposes no way to ask a glass or vibrant view what
    /// luminance it actually resolved to, and reading the real pixels behind
    /// the window needs Screen Recording permission. It's the one seam where
    /// a live sample would drop in, and everything else re-derives from it.
    struct ChromePalette {
        let backdrop: Color
        let panelTint: Color
        let fieldBG: Color
        let pillBG: Color
        let pillSelected: Color
        let pillStroke: Color

        /// The panel's own surface, once its tint is flattened onto the
        /// backdrop. This — not `backdrop` — is what the pills sit on.
        var surface: Color { Contrast.composite(panelTint, over: backdrop) }

        /// Whichever ink reads better on the panel itself.
        var ink: Color { Contrast.foreground(on: panelTint, over: backdrop) }
    }

    /// Fills are chosen so full-strength ink clears `Contrast.aaText` on every
    /// one of them. `pillSelected` is the value that used to be `white 0.34`:
    /// at that strength the *selected* tab measured 3.88:1 in dark mode, so
    /// selecting a tab actually made its label harder to read than leaving it
    /// alone. It's now light enough to stay distinct and dark enough to earn
    /// white text.
    static let darkChrome = ChromePalette(
        backdrop: Color(white: 0.24),
        panelTint: Color.white.opacity(0.10),
        fieldBG: Color.white.opacity(0.08),
        pillBG: Color.white.opacity(0.10),
        pillSelected: Color.white.opacity(0.21),
        pillStroke: Color.white.opacity(0.20))

    /// Light mode inverts which direction the fills pull: unselected pills
    /// darken the glass and the selected pill brightens it, which is both what
    /// macOS does with segmented controls and what lets one dark ink serve
    /// every fill here.
    static let lightChrome = ChromePalette(
        backdrop: Color(white: 0.78),
        panelTint: Color.white.opacity(0.18),
        fieldBG: Color.black.opacity(0.07),
        pillBG: Color.black.opacity(0.10),
        pillSelected: Color.white.opacity(0.55),
        pillStroke: Color.black.opacity(0.13))

    static let panelTint = chrome { $0.panelTint }
    static let fieldBG = chrome { $0.fieldBG }
    static let pillBG = chrome { $0.pillBG }
    static let pillSelected = chrome { $0.pillSelected }
    static let pillStroke = chrome { $0.pillStroke }

    /// Bar chrome that isn't a pill — the search field, the toolbar glyphs,
    /// the empty state. Muted and faint step down in weight only as far as
    /// their target allows; on a palette where 74% ink would fall under AA,
    /// `Contrast.muted` hands back a stronger opacity instead.
    static let chromeText = chrome(\.ink)
    static let chromeTextMuted = chrome { p in
        Contrast.muted(p.ink, opacity: 0.72, on: p.panelTint, over: p.backdrop)
    }
    static let chromeTextFaint = chrome { p in
        Contrast.muted(p.ink, opacity: 0.45, on: p.panelTint, over: p.backdrop,
                       target: Contrast.aaLarge)
    }

    /// A selected tab's label, measured on the selected fill; an unselected
    /// tab's, measured on the unselected fill. They can legitimately disagree
    /// about which ink wins, which is the entire point of asking per-surface.
    static let pillText = chrome { Contrast.foreground(on: $0.pillSelected, over: $0.surface) }
    static let pillTextMuted = chrome { p in
        Contrast.muted(Contrast.foreground(on: p.pillBG, over: p.surface),
                       opacity: 0.74, on: p.pillBG, over: p.surface)
    }

    /// Resolves a chrome color against the appearance in effect wherever it
    /// is drawn, so a single `static let` still tracks light/dark.
    private static func chrome(_ resolve: @escaping (ChromePalette) -> Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(resolve(isDark ? darkChrome : lightChrome))
        })
    }
}

extension Date {
    var clipRelative: String {
        let secs = -timeIntervalSinceNow
        switch secs {
        case ..<5:        return "Now"
        case ..<60:       return "\(Int(secs))s"
        case ..<3600:     return "\(Int(secs / 60))m"
        case ..<86_400:   return "\(Int(secs / 3600))h"
        case ..<604_800:  return "\(Int(secs / 86_400))d"
        default:
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f.string(from: self)
        }
    }

    var clipRelativeLong: String {
        let secs = -timeIntervalSinceNow
        if secs < 8 { return "Just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: self, relativeTo: Date())
    }
}
