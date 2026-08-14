import Foundation
import SwiftUI

/// Pinboards keep clip membership by ID. This avoids duplicating a clip and
/// makes later cross-device conflict resolution deterministic.
struct PestyBoard: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorHex: String
    var clipIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#5B8DEF",
        clipIDs: [UUID] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.clipIDs = clipIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool { deletedAt != nil }

    var color: Color { Color(hex: colorHex) ?? .accentColor }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard let number = UInt64(value, radix: 16) else { return nil }

        let red, green, blue, opacity: Double
        switch value.count {
        case 6:
            red = Double((number >> 16) & 0xFF) / 255
            green = Double((number >> 8) & 0xFF) / 255
            blue = Double(number & 0xFF) / 255
            opacity = 1
        case 8:
            red = Double((number >> 24) & 0xFF) / 255
            green = Double((number >> 16) & 0xFF) / 255
            blue = Double((number >> 8) & 0xFF) / 255
            opacity = Double(number & 0xFF) / 255
        default:
            return nil
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
