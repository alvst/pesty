import Foundation
import SwiftUI

/// Pinboards keep ordered membership by ID. Each member is a container-owned
/// clip copy with its own UUID, matching the CloudKit record model.
struct PestyBoard: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorHex: String
    var clipIDs: [UUID]
    var pinnedClipIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date
    var sortIndex: Int
    var deletedAt: Date?
    var deletionFinalizedAt: Date?
    /// The version that was live before a pending deletion, so sync keeps
    /// publishing that version instead of the tombstone during the window.
    var preDeletionUpdatedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#5B8DEF",
        clipIDs: [UUID] = [],
        pinnedClipIDs: [UUID] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sortIndex: Int = 0,
        deletedAt: Date? = nil,
        deletionFinalizedAt: Date? = nil,
        preDeletionUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.clipIDs = clipIDs
        self.pinnedClipIDs = pinnedClipIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortIndex = sortIndex
        self.deletedAt = deletedAt
        self.deletionFinalizedAt = deletionFinalizedAt
        self.preDeletionUpdatedAt = preDeletionUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, clipIDs, pinnedClipIDs
        case createdAt, updatedAt, sortIndex, deletedAt, deletionFinalizedAt, preDeletionUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#5B8DEF"
        clipIDs = try container.decodeIfPresent([UUID].self, forKey: .clipIDs) ?? []
        pinnedClipIDs = try container.decodeIfPresent([UUID].self, forKey: .pinnedClipIDs) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        deletionFinalizedAt = try container.decodeIfPresent(Date.self, forKey: .deletionFinalizedAt)
        preDeletionUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .preDeletionUpdatedAt)
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
