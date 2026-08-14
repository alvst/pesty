import SwiftUI

struct BoardsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var isPresentingNewBoard = false

    var body: some View {
        NavigationStack {
            Group {
                if store.boards.isEmpty {
                    ContentUnavailableView {
                        Label("No pinboards yet", systemImage: "rectangle.3.group")
                    } description: {
                        Text("Pin the clips you reuse most into color-coded collections.")
                    } actions: {
                        Button("Create a pinboard") { isPresentingNewBoard = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.boards) { board in
                            NavigationLink {
                                BoardDetailView(boardID: board.id)
                            } label: {
                                BoardRow(board: board, count: store.clips(in: board).count)
                            }
                        }
                        .onDelete { offsets in
                            let visibleBoards = store.boards
                            for id in offsets.compactMap({ index in
                                visibleBoards.indices.contains(index) ? visibleBoards[index].id : nil
                            }) {
                                store.deleteBoard(id: id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pinboards")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.undoableDeletedBoard != nil {
                        Button("Undo", systemImage: "arrow.uturn.backward") {
                            store.undoBoardDeletion()
                        }
                        .accessibilityLabel("Undo pinboard deletion")
                    }
                    Button {
                        isPresentingNewBoard = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create pinboard")
                }
            }
            .sheet(isPresented: $isPresentingNewBoard) {
                NewBoardSheet()
            }
        }
    }
}

private struct BoardRow: View {
    let board: PestyBoard
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(board.color)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "pin.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(board.name).font(.body.weight(.semibold))
                Text("\(count) \(count == 1 ? "clip" : "clips")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct BoardDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var store
    let boardID: UUID

    var body: some View {
        Group {
            if let board = store.board(id: boardID) {
                let clips = store.clips(in: board)
                ScrollView {
                    if clips.isEmpty {
                        ContentUnavailableView(
                            "Nothing pinned here",
                            systemImage: "pin.slash",
                            description: Text("Use a clip’s Pinboard menu to add it to \(board.name).")
                        )
                        .padding(.top, 80)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(clips) { clip in
                                NavigationLink {
                                    ClipDetailView(clipID: clip.id)
                                } label: {
                                    ClipCard(
                                        clip: clip,
                                        isRecentlyCopied: store.lastCopiedClipID == clip.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Remove from pinboard", systemImage: "pin.slash") {
                                        store.remove(clip, from: board)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(board.name)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Delete", role: .destructive) {
                            store.deleteBoard(id: board.id)
                            dismiss()
                        }
                    }
                }
            } else {
                ContentUnavailableView("Pinboard unavailable", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

private struct NewBoardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var store

    @State private var name = ""
    @State private var colorHex = "#5B8DEF"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Color (#RRGGBB)", text: $colorHex)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                HStack {
                    Circle()
                        .fill(Color(hex: colorHex) ?? .accentColor)
                        .frame(width: 24, height: 24)
                    Text("Preview")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Pinboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        store.addBoard(name: name, colorHex: Color(hex: colorHex) == nil ? "#5B8DEF" : colorHex)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
