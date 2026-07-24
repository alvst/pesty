import SwiftUI

enum Theme {
    static let cardWidth: CGFloat = 215
    static let cardSpacing: CGFloat = 12
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
