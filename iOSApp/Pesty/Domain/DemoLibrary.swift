import UIKit

/// The iPhone counterpart of the Mac's `--demo` launch: a fixed library for
/// screenshots that looks the same on every launch and never touches the
/// real one. Launch with the `--demo` argument (the "Pesty Demo"
/// scheme, or `simctl launch … --demo`).
enum DemoLibrary {
    static var isRequested: Bool { CommandLine.arguments.contains("--demo") }

    static func make(now: Date = .now) -> PestyLibrary {
        func clip(_ kind: ClipKind, _ text: String? = nil, app: String, bundle: String,
                  ago: TimeInterval, colorHex: String? = nil, fileNames: [String] = [],
                  in board: UUID? = nil, image: (name: String, hash: String)? = nil) -> PestyClip {
            PestyClip(
                containerID: board,
                kind: kind,
                text: text,
                imageAssetID: image?.name,
                imageHash: image?.hash,
                fileNames: fileNames,
                colorHex: colorHex,
                sourceBundleID: bundle,
                sourceAppName: app,
                capturedAt: now.addingTimeInterval(-ago),
                updatedAt: now.addingTimeInterval(-ago)
            )
        }

        let sample = sampleImage()
        var history: [PestyClip] = [
            clip(.text, "The quickest way to paste is to press Return on the highlighted card.",
                 app: "Notes", bundle: "com.apple.Notes", ago: 12),
            clip(.link, "https://github.com/alvst/pesty",
                 app: "Safari", bundle: "com.apple.Safari", ago: 90),
            clip(.text, "func paste(_ item: ClipItem) {\n    pasteboard.clearContents()\n    pasteboard.setString(item.text, forType: .string)\n}",
                 app: "Xcode", bundle: "com.apple.dt.Xcode", ago: 340),
            clip(.color, app: "Xcode", bundle: "com.apple.dt.Xcode", ago: 600, colorHex: "#5B8DEF"),
            clip(.text, "ceo@greycorelabs.com", app: "Mail", bundle: "com.apple.mail", ago: 1_200),
            clip(.file, "Q3-Report.pdf", app: "Finder", bundle: "com.apple.finder", ago: 3_600,
                 fileNames: ["Q3-Report.pdf"]),
            clip(.link, "https://swift.org", app: "Safari", bundle: "com.apple.Safari", ago: 7_200),
            clip(.text, "Remember to notarize the build before publishing the release.",
                 app: "Reminders", bundle: "com.apple.reminders", ago: 9_000)
        ]
        if let sample {
            history.insert(clip(.image, app: "Preview", bundle: "com.apple.Preview", ago: 200, image: sample), at: 2)
        }

        // Boards a real person would keep, each already holding the kind of
        // clip its name promises — an empty Pinboard demonstrates nothing.
        var boards: [PestyBoard] = []
        var copies: [PestyClip] = []
        func board(_ name: String, _ colorHex: String, _ members: (UUID) -> [PestyClip]) {
            let id = UUID()
            let items = members(id)
            boards.append(PestyBoard(id: id, name: name, colorHex: colorHex,
                                     clipIDs: items.map(\.id),
                                     createdAt: now.addingTimeInterval(-200_000),
                                     updatedAt: now.addingTimeInterval(-4_000),
                                     sortIndex: boards.count))
            copies += items
        }
        board("Snippets", "#0A84FF") { id in [
            clip(.text, "git log --oneline --graph --decorate --all",
                 app: "Terminal", bundle: "com.apple.Terminal", ago: 4_800, in: id),
            clip(.text, "swift build -c release --arch arm64 --arch x86_64",
                 app: "Terminal", bundle: "com.apple.Terminal", ago: 26_000, in: id),
            clip(.text, "@MainActor\nfinal class ClipboardMonitor {\n    private var timer: Timer?\n}",
                 app: "Xcode", bundle: "com.apple.dt.Xcode", ago: 92_000, in: id)
        ] }
        board("Brand", "#BF3BE0") { id in [
            clip(.color, app: "Figma", bundle: "com.figma.Desktop", ago: 51_000, colorHex: "#0A84FF", in: id),
            clip(.color, app: "Figma", bundle: "com.figma.Desktop", ago: 51_200, colorHex: "#FF2D55", in: id),
            clip(.text, "Pesty — your clipboard, kept.", app: "Notes", bundle: "com.apple.Notes", ago: 138_000, in: id)
        ] }
        board("Links", "#34C759") { id in [
            clip(.link, "https://developer.apple.com/documentation/appkit/nspasteboard",
                 app: "Safari", bundle: "com.apple.Safari", ago: 17_000, in: id),
            clip(.link, "https://developer.apple.com/design/human-interface-guidelines/menus",
                 app: "Safari", bundle: "com.apple.Safari", ago: 64_000, in: id)
        ] }
        board("Replies", "#FF8A2B") { id in [
            clip(.text, "Thanks for the report! I've reproduced this and it's fixed in the next build.",
                 app: "Mail", bundle: "com.apple.mail", ago: 8_400, in: id),
            clip(.text, "Happy to help — could you send the version number from Pesty ▸ About?",
                 app: "Mail", bundle: "com.apple.mail", ago: 120_000, in: id)
        ] }

        return PestyLibrary(clips: history + copies, boards: boards, updatedAt: now)
    }

    /// A rendered placeholder rather than a bundled photo: nothing to license,
    /// and it is written through the normal asset store so the card and the
    /// detail view load it exactly like a synced image. The real library's
    /// asset cleanup removes it again once nothing references it.
    private static func sampleImage() -> (name: String, hash: String)? {
        let size = CGSize(width: 1200, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let colors = [UIColor(red: 0.36, green: 0.55, blue: 0.94, alpha: 1).cgColor,
                          UIColor(red: 0.75, green: 0.23, blue: 0.88, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                     end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let title = "Pesty"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 160, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92)
            ]
            let textSize = title.size(withAttributes: attributes)
            title.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                   y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
        guard let data = image.pngData(),
              let stored = try? LocalAssetPersistence.storeImageData(data, preferredName: "demo-sample") else {
            return nil
        }
        return stored
    }
}

/// Demo launches never talk to iCloud.
final class NoCloudSyncService: LibrarySyncing {
    func start(target: any LibrarySyncTarget) { target.updateSyncStatus(.ready) }
    func localLibraryDidChange() {}
    func fetchNow() {}
    func refreshOnActivate() {}
    func rebuildLocalReplica() {}
}
