import SwiftUI

/// The iPhone and iPad companion use the same visual language as the Mac app:
/// a bright source-app header, an opaque near-white card body, and vivid blue
/// selection chrome. iOS cannot read another app's icon, so known system apps
/// use their icon hue and everything else receives a stable source-based hue.
enum PestyPalette {
    static let cardBody = Color.white.opacity(0.96)
    static let cardBorder = Color.black.opacity(0.12)
    static let selection = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let textPrimary = Color.black.opacity(0.82)
    static let textSecondary = Color.black.opacity(0.52)
    static let textTertiary = Color.black.opacity(0.34)
    static let headerText = Color.white
    static let headerSubtext = Color.white.opacity(0.80)

    private static let fallback = Color(red: 0.02, green: 0.48, blue: 1.0)
    private static let sourcePalette: [Color] = [
        Color(red: 0.02, green: 0.48, blue: 1.00),
        Color(red: 0.00, green: 0.66, blue: 0.57),
        Color(red: 0.20, green: 0.78, blue: 0.35),
        Color(red: 1.00, green: 0.58, blue: 0.10),
        Color(red: 1.00, green: 0.23, blue: 0.31),
        Color(red: 0.69, green: 0.24, blue: 0.93),
        Color(red: 0.88, green: 0.18, blue: 0.55),
        Color(red: 0.02, green: 0.70, blue: 0.84)
    ]

    static func sourceColor(for clip: PestyClip) -> Color {
        if let known = knownSourceColor(bundleID: clip.sourceBundleID, name: clip.sourceAppName) {
            return known
        }
        guard let source = [clip.sourceBundleID, clip.sourceAppName]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return fallback
        }
        return sourcePalette[stableIndex(for: source, count: sourcePalette.count)]
    }

    private static func knownSourceColor(bundleID: String?, name: String?) -> Color? {
        let source = "\(bundleID ?? "") \(name ?? "")".lowercased()
        let mappings: [(needles: [String], color: Color)] = [
            (["safari", "com.apple.mobilesafari"], Color(red: 0.02, green: 0.55, blue: 0.96)),
            (["messages", "com.apple.mobilesms", "com.apple.messages"], Color(red: 0.12, green: 0.78, blue: 0.35)),
            (["mail", "com.apple.mobilemail"], Color(red: 0.03, green: 0.48, blue: 0.97)),
            (["notes", "com.apple.mobilenotes"], Color(red: 0.96, green: 0.67, blue: 0.03)),
            (["music", "com.apple.mobileipod"], Color(red: 0.96, green: 0.18, blue: 0.35)),
            (["photos", "com.apple.mobileslideshow"], Color(red: 0.95, green: 0.36, blue: 0.22)),
            (["finder", "com.apple.finder"], Color(red: 0.12, green: 0.55, blue: 0.93)),
            (["xcode", "com.apple.dt.xcode"], Color(red: 0.02, green: 0.56, blue: 0.90)),
            (["slack", "com.tinyspeck"], Color(red: 0.45, green: 0.18, blue: 0.58)),
            (["chrome", "com.google.chrome"], Color(red: 0.09, green: 0.52, blue: 0.94)),
            (["firefox", "org.mozilla.firefox"], Color(red: 0.50, green: 0.20, blue: 0.87)),
            (["terminal", "com.apple.terminal"], Color(red: 0.10, green: 0.35, blue: 0.25))
        ]
        return mappings.first(where: { mapping in
            mapping.needles.contains(where: source.contains)
        })?.color
    }

    private static func stableIndex(for source: String, count: Int) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in source.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}
