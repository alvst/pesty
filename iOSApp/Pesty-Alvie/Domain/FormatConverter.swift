import UIKit

/// How a clip is written to the pasteboard. Mirrors the Mac app's paste
/// formats so a rich clip can be copied the way the user wants to use it.
enum CopyFormat: CaseIterable, Identifiable {
    /// The clip exactly as captured.
    case original
    /// Text only, all formatting removed.
    case plainText
    /// Bold, italic, underline, and links survive; fonts, sizes, and colors
    /// are normalized away.
    case cleanFormatting
    /// Rich content converted to Markdown text.
    case markdown

    var id: Self { self }

    var title: String {
        switch self {
        case .original: "Copy"
        case .plainText: "Copy as Plain Text"
        case .cleanFormatting: "Copy with Clean Formatting"
        case .markdown: "Copy as Markdown"
        }
    }

    var symbol: String {
        switch self {
        case .original: "doc.on.doc"
        case .plainText: "textformat"
        case .cleanFormatting: "paintbrush"
        case .markdown: "number"
        }
    }
}

/// Converts rich clips for the "Clean Formatting" and "Markdown" copy
/// options. A UIKit port of the Mac app's converter; the phone only ever
/// has RTF for a clip, so that is the sole source.
enum FormatConverter {
    static func canConvert(_ clip: PestyClip) -> Bool {
        clip.kind == .richText && clip.richTextData != nil
    }

    private static func attributed(for clip: PestyClip) -> NSAttributedString? {
        guard let rtf = clip.richTextData else { return nil }
        return try? NSAttributedString(
            data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    /// Strips fonts, sizes, and colors while keeping the structure people
    /// mean when they say "formatting": bold, italic, underline,
    /// strikethrough, and links — everything else becomes the system font.
    static func cleanedRTF(for clip: PestyClip) -> Data? {
        guard let source = attributed(for: clip) else { return nil }
        let base = UIFont.preferredFont(forTextStyle: .body)
        let out = NSMutableAttributedString(string: source.string)
        let full = NSRange(location: 0, length: out.length)
        out.addAttribute(.font, value: base, range: full)

        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, range, _ in
            if let font = attrs[.font] as? UIFont {
                var kept: UIFontDescriptor.SymbolicTraits = []
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) { kept.insert(.traitBold) }
                if traits.contains(.traitItalic) { kept.insert(.traitItalic) }
                if !kept.isEmpty,
                   let descriptor = base.fontDescriptor.withSymbolicTraits(kept) {
                    out.addAttribute(.font, value: UIFont(descriptor: descriptor, size: base.pointSize), range: range)
                }
            }
            if let underline = attrs[.underlineStyle] {
                out.addAttribute(.underlineStyle, value: underline, range: range)
            }
            if let strike = attrs[.strikethroughStyle] {
                out.addAttribute(.strikethroughStyle, value: strike, range: range)
            }
            if let link = attrs[.link] {
                out.addAttribute(.link, value: link, range: range)
            }
        }
        return try? out.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// Walks the attributed runs producing Markdown for bold, italic, and
    /// links. Markers never wrap line breaks — each line segment inside a
    /// styled run is marked separately so the output stays valid Markdown.
    static func markdown(for clip: PestyClip) -> String? {
        guard let source = attributed(for: clip) else { return nil }
        var out = ""
        let text = source.string as NSString

        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, range, _ in
            let chunk = text.substring(with: range)
            guard !chunk.isEmpty else { return }

            let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            var marker = ""
            if traits.contains(.traitBold) { marker += "**" }
            if traits.contains(.traitItalic) { marker += "*" }
            let linkTarget: String? = (attrs[.link] as? URL)?.absoluteString
                ?? attrs[.link] as? String

            // Split on newlines, keeping empty segments so blank lines survive.
            let segments = chunk.components(separatedBy: "\n")
            for (index, segment) in segments.enumerated() {
                if index > 0 { out += "\n" }
                guard !segment.isEmpty else { continue }
                // Markers hug the visible text; whitespace stays outside them.
                let leading = segment.prefix(while: { $0 == " " || $0 == "\t" })
                let trailing = String(segment.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
                let core = segment.dropFirst(leading.count).dropLast(trailing.count)
                guard !core.isEmpty else { out += segment; continue }

                var rendered = String(core)
                if let linkTarget, rendered.trimmingCharacters(in: .whitespaces) != linkTarget {
                    rendered = "[\(rendered)](\(linkTarget))"
                }
                if !marker.isEmpty {
                    rendered = "\(marker)\(rendered)\(String(marker.reversed()))"
                }
                out += leading + rendered + trailing
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
