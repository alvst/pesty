import SwiftUI

enum Theme {
    static let cardWidth: CGFloat = 215
    static let cardSpacing: CGFloat = 28
    static let cornerRadius: CGFloat = 16
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

    static let panelTint = Color.white.opacity(0.10)
    static let cardBody = Color.white.opacity(0.94)
    static let cardBorder = Color.black.opacity(0.12)
    static let selection = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let selectedCardRing: CGFloat = 6
    // Leave 43 pt beyond the selected-card ring at either strip edge while
    // preserving the ScrollView's normal clipping behavior.
    static let cardStripHorizontalPadding: CGFloat = selectedCardRing + 43

    static let chromeTextPrimary = Color.white.opacity(0.95)
    static let chromeTextSecondary = Color.white.opacity(0.55)
    static let chromeTextTertiary = Color.white.opacity(0.34)

    static let cardTextPrimary = Color.black.opacity(0.82)
    static let cardTextSecondary = Color.black.opacity(0.52)
    static let cardTextTertiary = Color.black.opacity(0.34)

    static let headerText = Color.white
    static let headerSubText = Color.white.opacity(0.78)

    static let fieldBG = Color.white.opacity(0.09)
    static let pillBG = Color.white.opacity(0.10)
    static let pillSelected = Color.white.opacity(0.18)
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
