import SwiftUI

struct Pinboard: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorHex: String
    var items: [ClipItem]

    /// Clips promoted to the front of this board, newest promotion first.
    ///
    /// Only the promotion is stored here — `items` already holds the manual
    /// order that dragging a card produces, so this rides on top of it rather
    /// than duplicating it. IDs are kept rather than reordering `items` so
    /// that unpinning restores a clip to where the user had dragged it.
    var pinnedItemIDs: [UUID]

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, items, pinnedItemIDs
    }

    init(id: UUID = UUID(), name: String, colorHex: String = "#5B8DEF",
         items: [ClipItem] = [], pinnedItemIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.items = items
        self.pinnedItemIDs = pinnedItemIDs
    }

    /// Boards saved before pinning existed have no `pinnedItemIDs` key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        items = try c.decodeIfPresent([ClipItem].self, forKey: .items) ?? []
        pinnedItemIDs = try c.decodeIfPresent([UUID].self, forKey: .pinnedItemIDs) ?? []
    }

    var color: Color { Color(hex: colorHex) ?? .accentColor }

    func isPinned(_ itemID: UUID) -> Bool { pinnedItemIDs.contains(itemID) }

    /// Pinned clips first, in promotion order, then everything else in the
    /// board's own order. A pinned ID whose clip has since been deleted is
    /// skipped rather than leaving a gap.
    var orderedItems: [ClipItem] {
        guard !pinnedItemIDs.isEmpty else { return items }
        let pinned = Set(pinnedItemIDs)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pinnedItemIDs.compactMap { byID[$0] } + items.filter { !pinned.contains($0.id) }
    }

    /// Drops promotions whose clip is gone, so the list cannot grow forever.
    mutating func prunePins() {
        guard !pinnedItemIDs.isEmpty else { return }
        let existing = Set(items.map(\.id))
        pinnedItemIDs.removeAll { !existing.contains($0) }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        case 8:
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
