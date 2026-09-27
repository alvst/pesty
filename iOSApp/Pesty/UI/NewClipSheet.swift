import SwiftUI
import PhotosUI

struct NewClipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var store

    @State private var kind: ClipKind = .text
    @State private var text = ""
    @State private var title = ""
    @State private var colorHex = "#5B8DEF"
    @State private var photoSelection: PhotosPickerItem?
    @State private var imageData: Data?

    private var canSave: Bool {
        switch kind {
        case .color:
            return Color(hex: colorHex) != nil
        case .image:
            return imageData != nil
        case .file:
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
                        ForEach([ClipKind.text, .link, .richText, .image, .color]) { kind in
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

                if kind != .color && kind != .file {
                    Section("Image attachment") {
                        PhotosPicker(selection: $photoSelection, matching: .images) {
                            Label(
                                imageData == nil ? "Choose Photo" : "Choose Another Photo",
                                systemImage: "photo.on.rectangle"
                            )
                        }
                        if let imageData, let image = UIImage(data: imageData) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Button("Remove Photo", role: .destructive) {
                                imageData = nil
                                photoSelection = nil
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
                        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let savedKind: ClipKind = kind == .image && !trimmedText.isEmpty
                            ? .text : kind
                        store.addClip(
                            kind: savedKind,
                            text: text,
                            title: title,
                            colorHex: kind == .color ? colorHex : nil,
                            imageData: imageData
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: photoSelection) { _, selection in
                guard let selection else {
                    imageData = nil
                    return
                }
                Task {
                    do {
                        let data = try await selection.loadTransferable(type: Data.self)
                        await MainActor.run { imageData = data }
                    } catch {
                        await MainActor.run { store.errorMessage = error.localizedDescription }
                    }
                }
            }
        }
    }
}
