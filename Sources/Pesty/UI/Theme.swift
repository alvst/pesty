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

    static let panelTint = Color.white.opacity(0.10)
    static let cardBody = Color.white.opacity(0.94)
    static let cardBorder = Color.black.opacity(0.12)
    // The focus color needs to remain unmistakable against both bright and
    // saturated clip headers. Use the system's vivid blue rather than a muted
    // tint so keyboard navigation is effortless to follow.
    static let selection = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let selectedCardRing: CGFloat = 6

    static let textPrimary = Color.black.opacity(0.82)
    static let textSecondary = Color.black.opacity(0.52)
    static let textTertiary = Color.black.opacity(0.34)

    static let headerText = Color.white
    static let headerSubText = Color.white.opacity(0.78)

    static let fieldBG = Color.white.opacity(0.09)
    // Tab pills sit directly on the glass over arbitrary desktop content, so
    // they get stronger fills and explicit light text instead of relying on
    // vibrancy to find contrast.
    static let pillBG = Color.white.opacity(0.16)
    static let pillSelected = Color.white.opacity(0.34)
    static let pillStroke = Color.white.opacity(0.22)
    static let pillText = Color.white.opacity(0.96)
    static let pillTextMuted = Color.white.opacity(0.74)
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
