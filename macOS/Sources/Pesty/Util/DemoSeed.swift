import AppKit

extension ClipboardStore {
    /// Builds the demo store's entire contents — history *and* Pinboards —
    /// from scratch on every launch, so `--demo` always looks the same and
    /// never shows whatever boards and clips happen to be lying around. It
    /// only ever touches the separate demo store; see `isDemo`.
    func seedDemo() {
        let now = Date()

        let history: [ClipItem] = [
            ClipItem(type: .text,
                     text: "The quickest way to paste is to press Return on the highlighted card.",
                     sourceBundleID: "com.apple.Notes", sourceAppName: "Notes",
                     createdAt: now.addingTimeInterval(-12)),
            ClipItem(type: .link,
                     text: "https://github.com/alvst/pesty",
                     sourceBundleID: "com.google.Chrome", sourceAppName: "Google Chrome",
                     createdAt: now.addingTimeInterval(-90)),
            ClipItem(type: .text,
                     text: "func paste(_ item: ClipItem) {\n    pasteboard.clearContents()\n    pasteboard.setString(item.text, forType: .string)\n}",
                     sourceBundleID: "com.microsoft.VSCode", sourceAppName: "Visual Studio Code",
                     createdAt: now.addingTimeInterval(-340)),
            ClipItem(type: .color, colorHex: "#5B8DEF",
                     sourceBundleID: "com.pixelmatorteam.pixelmator.x", sourceAppName: "Pixelmator Pro",
                     createdAt: now.addingTimeInterval(-600)),
            ClipItem(type: .text,
                     text: "The release build looks great — ready when you are.",
                     sourceBundleID: "com.apple.MobileSMS", sourceAppName: "Messages",
                     createdAt: now.addingTimeInterval(-1200)),
            ClipItem(type: .file,
                     text: "Q3-Report.pdf",
                     fileURLs: ["file:///Users/me/Documents/Q3-Report.pdf"],
                     sourceBundleID: "com.apple.finder", sourceAppName: "Finder",
                     createdAt: now.addingTimeInterval(-3600)),
            ClipItem(type: .link,
                     text: "https://swift.org",
                     sourceBundleID: "com.apple.Safari", sourceAppName: "Safari",
                     createdAt: now.addingTimeInterval(-7200)),
            ClipItem(type: .text,
                     text: "Remember to notarize the build before publishing the release.",
                     sourceBundleID: "com.apple.reminders", sourceAppName: "Reminders",
                     createdAt: now.addingTimeInterval(-9000))
        ]

        // Boards a real person would keep, each already holding the kind of
        // clip its name promises — an empty Pinboard demonstrates nothing.
        let pinboards: [Pinboard] = [
            Pinboard(name: "Snippets", colorHex: "#0A84FF", items: [
                ClipItem(type: .text,
                         text: "git log --oneline --graph --decorate --all",
                         sourceBundleID: "com.apple.Terminal", sourceAppName: "Terminal",
                         createdAt: now.addingTimeInterval(-4_800)),
                ClipItem(type: .text,
                         text: "swift build -c release --arch arm64 --arch x86_64",
                         sourceBundleID: "com.apple.Terminal", sourceAppName: "Terminal",
                         createdAt: now.addingTimeInterval(-26_000)),
                ClipItem(type: .text,
                         text: "@MainActor\nfinal class ClipboardMonitor {\n    private var timer: Timer?\n}",
                         sourceBundleID: "com.apple.dt.Xcode", sourceAppName: "Xcode",
                         createdAt: now.addingTimeInterval(-92_000))
            ]),
            Pinboard(name: "Brand", colorHex: "#BF3BE0", items: [
                ClipItem(type: .color, colorHex: "#0A84FF",
                         sourceBundleID: "com.figma.Desktop", sourceAppName: "Figma",
                         createdAt: now.addingTimeInterval(-51_000)),
                ClipItem(type: .color, colorHex: "#FF2D55",
                         sourceBundleID: "com.figma.Desktop", sourceAppName: "Figma",
                         createdAt: now.addingTimeInterval(-51_200)),
                ClipItem(type: .text,
                         text: "Pesty — your clipboard, kept.",
                         sourceBundleID: "com.apple.Notes", sourceAppName: "Notes",
                         createdAt: now.addingTimeInterval(-138_000))
            ]),
            Pinboard(name: "Links", colorHex: "#34C759", items: [
                ClipItem(type: .link,
                         text: "https://developer.apple.com/documentation/appkit/nspasteboard",
                         sourceBundleID: "com.apple.Safari", sourceAppName: "Safari",
                         createdAt: now.addingTimeInterval(-17_000)),
                ClipItem(type: .link,
                         text: "https://developer.apple.com/design/human-interface-guidelines/menus",
                         sourceBundleID: "com.apple.Safari", sourceAppName: "Safari",
                         createdAt: now.addingTimeInterval(-64_000))
            ]),
            Pinboard(name: "Replies", colorHex: "#FF8A2B", items: [
                ClipItem(type: .text,
                         text: "Thanks for the report! I've reproduced this and it's fixed in the next build.",
                         sourceBundleID: "com.apple.mail", sourceAppName: "Mail",
                         createdAt: now.addingTimeInterval(-8_400)),
                ClipItem(type: .text,
                         text: "Happy to help — could you send the version number from Pesty ▸ About?",
                         sourceBundleID: "com.apple.mail", sourceAppName: "Mail",
                         createdAt: now.addingTimeInterval(-120_000))
            ])
        ]

        replaceAllForDemo(history: history, pinboards: pinboards)
    }
}
