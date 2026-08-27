import Foundation

/// The bar's card selection, kept apart from `ClipboardStore` so its rules —
/// which are entirely about ordering, anchors, and what survives a change —
/// can be reasoned about and tested against a plain list of IDs.
///
/// Every method takes the current visible order rather than storing it: what
/// is on screen changes with the search query and the chosen Pinboard, and a
/// selection that remembered a stale order would extend across cards the user
/// cannot see.
struct ClipSelection: Equatable {
    /// Every selected card.
    private(set) var ids: Set<UUID> = []

    /// The card arrow keys move from, modifier-clicks measure against, and
    /// single-item actions use. Always a member of `ids` while non-empty.
    private(set) var lead: UUID?

    /// Where ⇧ measures its range from. It deliberately survives the range
    /// growing and shrinking — that is what stops shift-selection from
    /// ratcheting outward and never coming back.
    private(set) var anchor: UUID?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    var isMultiple: Bool { ids.count > 1 }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Replaces the selection with a single card, or clears it entirely.
    mutating func select(_ id: UUID?) {
        lead = id
        anchor = id
        ids = id.map { [$0] } ?? []
    }

    /// ⌘-click: adds or removes one card, leaving the rest alone. Removing the
    /// lead promotes the first remaining card in `order`, so the keyboard
    /// always has somewhere to move from. A focused list keeps at least one
    /// card selected, so the final card will not toggle itself off.
    mutating func toggle(_ id: UUID, in order: [UUID]) {
        guard order.contains(id) else { return }
        if ids.contains(id) {
            guard ids.count > 1 else { return }
            ids.remove(id)
            if lead == id { lead = order.first(where: ids.contains) }
        } else {
            ids.insert(id)
            lead = id
        }
        anchor = lead
    }

    /// ⇧-click and ⇧-arrow: the contiguous run between the anchor and `id`.
    /// It replaces the previous range rather than adding to it, which is what
    /// lets the same gesture shrink a selection back down.
    mutating func extend(to id: UUID, in order: [UUID]) {
        guard let target = order.firstIndex(of: id) else { return }
        let from = anchor ?? lead ?? id
        let start = order.firstIndex(of: from) ?? target
        ids = Set(order[min(start, target)...max(start, target)])
        lead = id
        anchor = order[start]
    }

    mutating func selectAll(in order: [UUID]) {
        guard !order.isEmpty else { return }
        ids = Set(order)
        if lead == nil || !ids.contains(lead!) { lead = order.first }
        anchor = lead
    }

    /// Drops anything no longer on screen — after a delete, a new search, or a
    /// switch to another Pinboard.
    mutating func prune(to order: [UUID]) {
        let survivors = ids.intersection(order)
        guard survivors != ids else { return }
        ids = survivors
        if let lead, !survivors.contains(lead) {
            self.lead = order.first(where: survivors.contains)
        }
        if let anchor, !survivors.contains(anchor) { self.anchor = self.lead }
    }
}
