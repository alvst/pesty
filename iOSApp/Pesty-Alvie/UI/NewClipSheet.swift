import SwiftUI

struct NewClipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var store

    @State private var kind: ClipKind = .text
    @State private var text = ""
    @State private var title = ""
    @State private var colorHex = "#5B8DEF"

    private var canSave: Bool {
        switch kind {
        case .color:
            return Color(hex: colorHex) != nil
        case .image, .file:
            return false
        default:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Clip type", selection: $kind) {
                        ForEach([ClipKind.text, .link, .richText, .color]) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                }

                Section("Content") {
                    if kind == .color {
                        TextField("#RRGGBB", text: $colorHex)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    } else {
                        TextEditor(text: $text)
                            .frame(minHeight: 150)
                            .overlay(alignment: .topLeading) {
                                if text.isEmpty {
                                    Text(kind == .link ? "https://example.com" : "Paste or type content")
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }

                Section("Optional") {
                    TextField("Title", text: $title)
                }
            }
            .navigationTitle("New Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.addClip(
                            kind: kind,
                            text: text,
                            title: title,
                            colorHex: kind == .color ? colorHex : nil
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
