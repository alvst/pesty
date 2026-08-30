import SwiftUI
import WidgetKit

@main
struct PestyWidgetBundle: WidgetBundle {
    var body: some Widget {
        PestyRecentClipsWidget()
    }
}

struct PestyRecentClipsWidget: Widget {
    let kind = "PestyRecentClips"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PestyTimelineProvider()) { entry in
            PestyWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent Clips")
        .description("Open your latest Pesty-Alvie clips, search, or add something new.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct PestyEntry: TimelineEntry {
    let date: Date
    let clips: [PestyClip]
}

private struct PestyTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PestyEntry {
        PestyEntry(date: .now, clips: [
            PestyClip(kind: .link, text: "https://apple.com", sourceAppName: "Safari"),
            PestyClip(kind: .text, text: "A useful note", sourceAppName: "Notes")
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (PestyEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PestyEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    private func entry() -> PestyEntry {
        PestyEntry(date: .now, clips: Array(LocalLibraryPersistence.load().activeClips.prefix(6)))
    }
}

private struct PestyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PestyEntry

    private var visibleCount: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 2
        default: 4
        }
    }

    var body: some View {
        Group {
            if entry.clips.isEmpty {
                emptyView
            } else if family == .systemSmall {
                smallView(entry.clips[0])
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Label("Recent", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.bold))
                        Spacer()
                        Link(destination: URL(string: "pesty-alvie://search")!) {
                            Image(systemName: "magnifyingglass")
                        }
                        Link(destination: URL(string: "pesty-alvie://new")!) {
                            Image(systemName: "plus")
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 40)

                    Divider()

                    ForEach(Array(entry.clips.prefix(visibleCount))) { clip in
                        Link(destination: clip.deepLink) {
                            WidgetClipRow(clip: clip)
                        }
                        if clip.id != entry.clips.prefix(visibleCount).last?.id { Divider() }
                    }
                }
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private func smallView(_ clip: PestyClip) -> some View {
        Link(destination: clip.deepLink) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(clip.kind.title, systemImage: clip.kind.symbol)
                        .font(.caption.weight(.bold))
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(12)
                .background(PestyPalette.sourceColor(for: clip))

                VStack(alignment: .leading, spacing: 5) {
                    Text(clip.displayTitle)
                        .font(.headline)
                        .foregroundStyle(PestyPalette.textPrimary)
                        .lineLimit(3)
                    if let preview = clip.previewText, preview != clip.displayTitle {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(PestyPalette.textSecondary)
                            .lineLimit(3)
                            .privacySensitive()
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
        }
    }

    private var emptyView: some View {
        Link(destination: URL(string: "pesty-alvie://new")!) {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.title)
                    .foregroundStyle(PestyPalette.selection)
                Text("Add your first clip")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Tap to open Pesty-Alvie")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

private struct WidgetClipRow: View {
    let clip: PestyClip

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(PestyPalette.sourceColor(for: clip))
                .frame(width: 7, height: 30)
            Image(systemName: clip.kind.symbol)
                .foregroundStyle(PestyPalette.sourceColor(for: clip))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .privacySensitive()
                Text(clip.sourceAppName ?? clip.kind.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 42)
        .contentShape(Rectangle())
    }
}

private extension PestyClip {
    var deepLink: URL {
        URL(string: "pesty-alvie://clip/\(id.uuidString)")!
    }
}
