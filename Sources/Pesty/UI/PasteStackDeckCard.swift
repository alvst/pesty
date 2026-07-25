import SwiftUI

/// A compact representation of one saved Paste Stack in the Clipboard strip.
/// It opens that stack rather than exposing its clips as history cards.
struct PasteStackDeckCard: View {
    let stack: SavedPasteStack
    let isActive: Bool
    let isCollecting: Bool

    private var nextEntry: PasteStackEntry? {
        stack.displayEntries.first(where: { !$0.isPasted })
    }

    var body: some View {
        Button { AppController.shared.showPasteStackTab(stackID: stack.id) } label: {
            ZStack(alignment: .topLeading) {
                if stack.pendingCount > 2 { deckLayer(offset: 12, opacity: 0.20) }
                if stack.pendingCount > 1 { deckLayer(offset: 6, opacity: 0.34) }
                frontCard
            }
            .frame(width: Theme.cardWidth + 12, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .help("Open Paste Stack")
        .contextMenu {
            Button(role: .destructive) {
                AppController.shared.pasteSequence.deleteStack(stack.id)
            } label: {
                Label("Delete Paste Stack", systemImage: "trash")
            }
        }
    }

    private func deckLayer(offset: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
            .fill(Theme.selection.opacity(opacity))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(Theme.selection.opacity(0.25))
            }
            .offset(x: offset, y: offset)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
    }

    private var frontCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 16, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Paste Stack")
                        .font(.system(size: 15, weight: .bold))
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.headerSubText)
                }
                Spacer(minLength: 4)
                Text("\(stack.pendingCount)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .foregroundStyle(Theme.headerText)
            .padding(.horizontal, 13)
            .frame(height: Theme.headerHeight)
            .background(Theme.selection)

            VStack(spacing: 10) {
                if let entry = nextEntry {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(entry.item.type.accent.opacity(0.18))
                        .frame(width: 50, height: 50)
                        .overlay {
                            Image(systemName: entry.item.type.symbol)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(entry.item.type.accent)
                        }
                    Text(entry.item.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                    Text("Next clip")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.selection)
                    Text("Stack complete")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.cardBody)

            HStack {
                Text("\(stack.pendingCount) queued")
                Spacer()
                Text("Open stack")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(Theme.cardBody)
        }
        .frame(width: Theme.cardWidth)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(isActive ? Theme.selection.opacity(0.9) : Theme.selection.opacity(0.45),
                              lineWidth: isActive ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
    }

    private var statusText: String {
        if isActive && isCollecting { return "Collecting clips" }
        if stack.pendingCount > 0 { return "Ready to paste" }
        return "Completed stack"
    }
}
