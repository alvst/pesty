import SwiftUI

@MainActor
enum SourceColor {
    private static let palette: [Color] = [
        Color(red: 0.24, green: 0.61, blue: 0.95),
        Color(red: 0.22, green: 0.29, blue: 0.93),
        Color(red: 0.06, green: 0.12, blue: 0.31),
        Color(red: 0.12, green: 0.53, blue: 0.51),
        Color(red: 0.43, green: 0.33, blue: 0.80),
        Color(red: 0.69, green: 0.37, blue: 0.59),
        Color(red: 0.78, green: 0.40, blue: 0.34),
        Color(red: 0.82, green: 0.62, blue: 0.20)
    ]

    private static let knownColors: [String: Color] = [
        "com.apple.dt.Xcode": palette[0],
        "com.apple.Safari": palette[0],
        "com.apple.finder": palette[0],
        "com.openai.chat": palette[2],
        "com.openai.chatgpt": palette[2],
        "com.apple.Terminal": palette[2],
        "com.apple.Preview": palette[4],
        "com.apple.Notes": palette[7]
    ]
    private static var cache: [String: Color] = [:]

    static func color(for bundleID: String?) -> Color {
        guard let id = bundleID, !id.isEmpty else { return palette[0] }
        if let color = cache[id] { return color }
        let color = knownColors[id] ?? palette[stableIndex(for: id)]
        cache[id] = color
        return color
    }

    private static func stableIndex(for identifier: String) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(palette.count))
    }
}
