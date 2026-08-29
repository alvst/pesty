import SwiftUI

struct ClipDetailView: View {
    @Environment(LibraryStore.self) private var store
    let clipID: UUID

    @State private var didCopy = false

    var body: some View {
        Group {
            if let clip = store.clip(id: clipID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ClipPreview(clip: clip)

                        VStack(alignment: .leading, spacing: 8) {
                            Label(clip.kind.title, systemImage: clip.kind.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(clip.kind.tint)
                            Text(clip.displayTitle)
                                .font(.title2.weight(.bold))
                            if let text = clip.previewText,
                               clip.kind != .color {
                                Text(text)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        LabeledContent("Captured") {
                            Text(clip.capturedAt, format: .dateTime.month().day().year().hour().minute())
                        }
                        if let source = clip.sourceAppName {
                            LabeledContent("Source app") { Text(source) }
                        }
                        if let device = clip.sourceDeviceName {
                            LabeledContent("Device") { Text(device) }
                        }
                        if let lastUsed = clip.lastUsedAt {
                            LabeledContent("Last copied") {
                                Text(lastUsed, format: .relative(presentation: .named))
                            }
                        }

                        if !store.boards.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Pinboards")
                                    .font(.headline)
                                ForEach(store.boards) { board in
                                    Button {
                                        store.toggle(clip, in: board)
                                    } label: {
                                        HStack {
                                            Circle().fill(board.color).frame(width: 10, height: 10)
                                            Text(board.name)
                                            Spacer()
                                            if store.contains(clip, in: board) {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                Image(systemName: "plus")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding()
                }
                .navigationTitle("Clip")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    Button(action: { copy(clip) }) {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                    .background(.ultraThinMaterial)
                }
                .toolbar {
                    if clip.kind == .image,
                       let imageURL = LocalAssetPersistence.url(for: clip.imageAssetID) {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: imageURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    } else if let text = clip.copyableText {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: text) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Clip unavailable", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func copy(_ clip: PestyClip) {
        do {
            try ClipboardWriter.copy(clip)
            store.markCopied(clip)
            didCopy = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}

private struct ClipPreview: View {
    let clip: PestyClip

    var body: some View {
        Group {
            if clip.kind == .color, let color = Color(hex: clip.colorHex ?? "") {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(color)
                    .frame(height: 180)
                    .overlay {
                        Text(clip.colorHex ?? "")
                            .font(.title2.monospaced().weight(.bold))
                            .foregroundStyle(color.isLight ? .black : .white)
                    }
            } else if clip.kind == .image,
                      let url = LocalAssetPersistence.url(for: clip.imageAssetID),
                      let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 420)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityLabel(clip.displayTitle)
            } else if clip.kind == .image {
                UnavailablePayloadPreview(symbol: "photo", text: "Image asset unavailable on this device")
            } else if clip.kind == .file && clip.fileNames.isEmpty {
                UnavailablePayloadPreview(symbol: "doc", text: "File is available on its source device")
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(clip.kind.tint.opacity(0.14))
                    .frame(height: 104)
                    .overlay {
                        Image(systemName: clip.kind.symbol)
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(clip.kind.tint)
                    }
            }
        }
    }
}

private struct UnavailablePayloadPreview: View {
    let symbol: String
    let text: String

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.quaternary)
            .frame(height: 160)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 34))
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
    }
}

private extension Color {
    var isLight: Bool {
        guard let components = UIColor(self).cgColor.components else { return false }
        let red = components.count > 2 ? components[0] : components[0]
        let green = components.count > 2 ? components[1] : components[0]
        let blue = components.count > 2 ? components[2] : components[0]
        return (0.299 * red + 0.587 * green + 0.114 * blue) > 0.65
    }
}
