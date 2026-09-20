import AppKit
import SwiftUI
import XCTest
@testable import Pesty

@MainActor
final class RichTextPreviewTests: XCTestCase {
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    func testWhiteTextWithoutABackgroundIsReadableOnCardsInBothThemes() throws {
        let original = NSAttributedString(string: "192.0.2.42", attributes: [.foregroundColor: NSColor.white])
        for name in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let output = RichTextPreview.readable(original, on: RichTextPreview.Surface.card.background,
                                                 appearance: appearance)
            try assertReadable(output, on: RichTextPreview.Surface.card.background, appearance: appearance)
            try assertReadable(output, on: .white, appearance: appearance)
        }
        XCTAssertEqual(original.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .white)
        XCTAssertNil(original.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testInlinePreviewInkWorksAcrossItsTranslucentWhiteSurface() throws {
        for originalColor in [NSColor.white, .yellow, .green, .gray, .black] {
            let original = NSAttributedString(string: "preview", attributes: [.foregroundColor: originalColor])
            let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
            let output = RichTextPreview.readable(original, on: RichTextPreview.Surface.inline.background,
                                                 appearance: appearance)
            for brightness in [0.58, 0.7, 0.85, 1.0] {
                try assertReadable(output,
                                   on: NSColor(srgbRed: brightness, green: brightness, blue: brightness, alpha: 1),
                                   appearance: appearance)
            }
        }
    }

    func testBlackTextAdaptsToADarkPreviewWindow() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let original = NSAttributedString(string: "dark preview", attributes: [.foregroundColor: NSColor.black])
        let output = RichTextPreview.readable(original, on: .windowBackgroundColor, appearance: appearance)
        try assertReadable(output, on: .windowBackgroundColor, appearance: appearance)
    }

    func testReadableHighlightsFontsAndLinksRemainIntact() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 17, weight: .bold)
        let link = try XCTUnwrap(URL(string: "https://example.com"))
        let original = NSAttributedString(string: "highlight", attributes: [
            .foregroundColor: NSColor.green, .backgroundColor: NSColor.black,
            .font: font, .link: link, .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let output = RichTextPreview.readable(original, on: .white, appearance: appearance)
        XCTAssertEqual(output.string, original.string)
        XCTAssertEqual(output.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
        XCTAssertEqual(output.attribute(.link, at: 0, effectiveRange: nil) as? URL, link)
        XCTAssertEqual(output.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        let green = try XCTUnwrap(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(Contrast.components(Color(nsColor: green)).green, 1, accuracy: 0.001)
        try assertReadable(output, on: .white, appearance: appearance)
    }

    func testFaintInkAndLowContrastHighlightAreCorrectedWithoutMutatingSource() throws {
        let original = NSAttributedString(string: "faint", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.1),
            .backgroundColor: NSColor.white.withAlphaComponent(0.2),
            .underlineColor: NSColor.white, .strikethroughColor: NSColor.white
        ])
        let before = NSAttributedString(attributedString: original)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let output = RichTextPreview.readable(original, on: .white, appearance: appearance)
        try assertReadable(output, on: .white, appearance: appearance)
        for key: NSAttributedString.Key in [.underlineColor, .strikethroughColor] {
            let color = try XCTUnwrap(output.attribute(key, at: 0, effectiveRange: nil) as? NSColor)
            XCTAssertGreaterThanOrEqual(Contrast.ratio(Color(nsColor: color), .white), Contrast.aaText)
        }
        XCTAssertTrue(original.isEqual(to: before))
    }

    func testMissingInkAndMiddleGrayBackgroundsStillClearTextContrast() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let background = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        for attributes: [NSAttributedString.Key: Any] in [
            [.backgroundColor: NSColor.black],
            [.foregroundColor: background],
            [.foregroundColor: NSColor.labelColor]
        ] {
            let output = RichTextPreview.readable(NSAttributedString(string: "text", attributes: attributes),
                                                 on: background, appearance: appearance)
            try assertReadable(output, on: background, appearance: appearance)
        }
    }

    func testEmptyContentIsSafe() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertEqual(RichTextPreview.readable(NSAttributedString(string: ""), on: .white,
                                               appearance: appearance).length, 0)
    }

    func testPreviewCorrectionDoesNotChangeCopiedRTF() throws {
        let source = fixture()
        let data = try source.data(from: NSRange(location: 0, length: source.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let item = ClipItem(type: .richText, text: source.string, rtfData: data)
        let decoded = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                             documentAttributes: nil)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let preview = RichTextPreview.readable(decoded, on: .white, appearance: appearance)
        XCTAssertFalse(preview.isEqual(to: decoded))

        // A private pasteboard never overwrites the user's current clipboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        PasteService.copy(item, to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .rtf), data)
        XCTAssertEqual(pasteboard.string(forType: .string), source.string)
        XCTAssertEqual(item.rtfData, data)
    }

    /// Set PESTY_RICH_TEXT_SNAPSHOTS to inspect actual SwiftUI Text rendering.
    /// The image renderer never opens a window or interacts with a user's clip.
    func testRichTextRendersOnEveryPreviewSurfaceInBothThemes() throws {
        let source = fixture()
        let data = try source.data(from: NSRange(location: 0, length: source.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        for (theme, scheme, appearanceName) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                               ("dark", .dark, .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for (name, surface) in [("card", RichTextPreview.Surface.card), ("inline", .inline), ("window", .window)] {
                var rendered: NSImage?
                appearance.performAsCurrentDrawingAppearance {
                    let content = HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Original").font(.headline)
                            Text(AttributedString(source))
                                .frame(width: 250, height: 120, alignment: .topLeading)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Readable preview").font(.headline)
                            RichTextContent(rtfData: data, fallback: source.string, surface: surface)
                                .frame(width: 250, height: 120, alignment: .topLeading)
                        }
                    }
                    .padding(20)
                    .foregroundStyle(surface == .window ? Color.primary : Color.black)
                    .background(Color(nsColor: surface.background))
                    .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    rendered = renderer.nsImage
                }
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered?.tiffRepresentation)))
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertFalse(png.isEmpty)
                if let output = ProcessInfo.processInfo.environment["PESTY_RICH_TEXT_SNAPSHOTS"] {
                    let directory = URL(fileURLWithPath: output, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(to: directory.appendingPathComponent("\(name)-\(theme).png"))
                }
            }
        }
    }

    private func fixture() -> NSAttributedString {
        let text = "ssh demo@192.0.2.42\nWhite text\nBlack text\nReadable blue"
        let source = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        ])
        source.addAttributes([.foregroundColor: NSColor.green, .backgroundColor: NSColor.black],
                             range: (text as NSString).range(of: "ssh demo@"))
        source.addAttribute(.foregroundColor, value: NSColor.black, range: (text as NSString).range(of: "Black text"))
        source.addAttribute(.foregroundColor, value: NSColor.blue, range: (text as NSString).range(of: "Readable blue"))
        return source
    }

    private func assertReadable(_ text: NSAttributedString, on background: NSColor,
                                appearance: NSAppearance, file: StaticString = #filePath, line: UInt = #line) throws {
        var checked = 0
        appearance.performAsCurrentDrawingAppearance {
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
                guard let ink = attributes[.foregroundColor] as? NSColor else {
                    XCTFail("Missing preview ink", file: file, line: line)
                    return
                }
                let highlight = attributes[.backgroundColor] as? NSColor ?? background
                XCTAssertGreaterThanOrEqual(
                    Contrast.ratio(Color(nsColor: ink), on: Color(nsColor: highlight), over: Color(nsColor: background)),
                    Contrast.aaText, file: file, line: line)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, file: file, line: line)
    }
}
