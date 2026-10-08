import AppKit
import XCTest
@testable import Pesty

@MainActor
final class RichTextFormattingTests: XCTestCase {
    private let baseFont = RichTextFormatting.defaultFont

    func testMixedFontTraitEnablesEveryRunThenDisablesEveryRun() {
        let value = NSMutableAttributedString(string: "plain bold")
        value.addAttribute(.font, value: baseFont,
                           range: NSRange(location: 0, length: value.length))
        let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        value.addAttribute(.font, value: bold, range: NSRange(location: 6, length: 4))
        let full = NSRange(location: 0, length: value.length)

        XCTAssertEqual(RichTextFormatting.fontTraitState(.boldFontMask,
                                                         in: value, range: full), .mixed)
        XCTAssertTrue(RichTextFormatting.toggleFontTrait(.boldFontMask,
                                                         in: value, range: full))
        XCTAssertEqual(RichTextFormatting.fontTraitState(.boldFontMask,
                                                         in: value, range: full), .on)

        XCTAssertFalse(RichTextFormatting.toggleFontTrait(.boldFontMask,
                                                          in: value, range: full))
        XCTAssertEqual(RichTextFormatting.fontTraitState(.boldFontMask,
                                                         in: value, range: full), .off)
    }

    func testMixedDecorationUsesTheWholeSelectionInsteadOfItsFirstCharacter() {
        let value = NSMutableAttributedString(string: "under line")
        value.addAttribute(.font, value: baseFont,
                           range: NSRange(location: 0, length: value.length))
        value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                           range: NSRange(location: 6, length: 4))
        let full = NSRange(location: 0, length: value.length)

        XCTAssertEqual(RichTextFormatting.decorationState(.underlineStyle,
                                                          in: value, range: full), .mixed)
        XCTAssertTrue(RichTextFormatting.toggleDecoration(
            .underlineStyle, enabledValue: NSUnderlineStyle.single.rawValue,
            in: value, range: full
        ))
        XCTAssertEqual(RichTextFormatting.decorationState(.underlineStyle,
                                                          in: value, range: full), .on)

        XCTAssertFalse(RichTextFormatting.toggleDecoration(
            .underlineStyle, enabledValue: NSUnderlineStyle.single.rawValue,
            in: value, range: full
        ))
        XCTAssertEqual(RichTextFormatting.decorationState(.underlineStyle,
                                                          in: value, range: full), .off)
    }

    func testFontTransformPreservesUnrelatedTraitsAcrossRuns() {
        let value = NSMutableAttributedString(string: "small large")
        let italic = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask
        )
        let bold = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 24), toHaveTrait: .boldFontMask
        )
        value.addAttribute(.font, value: italic, range: NSRange(location: 0, length: 5))
        value.addAttribute(.font, value: bold, range: NSRange(location: 6, length: 5))

        RichTextFormatting.transformFonts(
            in: value, range: NSRange(location: 0, length: value.length)
        ) { NSFontManager.shared.convert($0, toSize: 30) }

        let first = value.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let second = value.attribute(.font, at: 6, effectiveRange: nil) as! NSFont
        XCTAssertEqual(first.pointSize, 30)
        XCTAssertEqual(second.pointSize, 30)
        XCTAssertTrue(NSFontManager.shared.traits(of: first).contains(.italicFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: second).contains(.boldFontMask))
    }

    func testClearFormattingRemovesTerminalStyleOnlyInsideSelection() {
        let text = "keep reset keep"
        let value = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: value.length)
        value.addAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: full)
        value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                           range: NSRange(location: 0, length: 4))

        let reset = (text as NSString).range(of: "reset")
        let terminalFont = NSFont.monospacedSystemFont(ofSize: 22, weight: .bold)
        value.addAttributes([
            .font: terminalFont,
            .foregroundColor: NSColor.systemGreen,
            .backgroundColor: NSColor.black,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .kern: 3,
            .baselineOffset: 2,
            .link: URL(string: "https://example.com")!
        ], range: reset)

        RichTextFormatting.clear(in: value, range: reset)

        let resetAttributes = value.attributes(at: reset.location, effectiveRange: nil)
        XCTAssertEqual(Set(resetAttributes.keys), [.font, .foregroundColor])
        XCTAssertTrue((resetAttributes[.font] as? NSFont)?.isEqual(baseFont) == true)
        XCTAssertTrue((resetAttributes[.foregroundColor] as? NSColor)?
            .isEqual(NSColor.labelColor) == true)
        XCTAssertNotNil(value.attribute(.underlineStyle, at: 0, effectiveRange: nil),
                        "formatting outside the selected range must survive")
        XCTAssertEqual(value.string, text)
    }

    func testAlignmentExpandsToIntersectingParagraphsAndPreservesIndentation() {
        let text = "one\ntwo\nthree"
        let value = NSMutableAttributedString(string: text)
        let style = NSMutableParagraphStyle()
        style.headIndent = 14
        style.lineSpacing = 5
        value.addAttributes([.font: baseFont, .paragraphStyle: style],
                            range: NSRange(location: 0, length: value.length))
        let selection = (text as NSString).range(of: "ne\ntw")

        RichTextFormatting.setAlignment(.center, in: value, selection: selection)

        let first = value.attribute(.paragraphStyle, at: 0,
                                    effectiveRange: nil) as! NSParagraphStyle
        let second = value.attribute(.paragraphStyle, at: 4,
                                     effectiveRange: nil) as! NSParagraphStyle
        let third = value.attribute(.paragraphStyle, at: 8,
                                    effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(first.alignment, .center)
        XCTAssertEqual(second.alignment, .center)
        XCTAssertEqual(third.alignment, .natural)
        XCTAssertEqual(first.headIndent, 14)
        XCTAssertEqual(second.lineSpacing, 5)
    }

    func testUTF16EmojiSelectionIsClampedAndFormattedWithoutChangingText() {
        let text = "A😀B"
        let value = NSMutableAttributedString(string: text)
        value.addAttribute(.font, value: baseFont,
                           range: NSRange(location: 0, length: value.length))
        let emoji = (text as NSString).range(of: "😀")

        RichTextFormatting.setAttribute(.foregroundColor, value: NSColor.systemPink,
                                        in: value, range: emoji)

        XCTAssertEqual(value.string, text)
        XCTAssertTrue((value.attribute(.foregroundColor, at: emoji.location,
                                       effectiveRange: nil) as? NSColor)?
            .isEqual(NSColor.systemPink) == true)
        XCTAssertNil(value.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(value.attribute(.foregroundColor, at: value.length - 1,
                                     effectiveRange: nil))
    }

    func testMeaningfulFormattingDistinguishesPlainEditorAttributes() {
        let plain = NSMutableAttributedString(string: "plain")
        plain.addAttributes([
            .font: RichTextFormatting.defaultFont,
            .foregroundColor: RichTextFormatting.defaultTextColor
        ], range: NSRange(location: 0, length: plain.length))
        XCTAssertFalse(RichTextFormatting.hasMeaningfulFormatting(plain))

        plain.addAttribute(.backgroundColor, value: NSColor.systemYellow,
                           range: NSRange(location: 0, length: 1))
        XCTAssertTrue(RichTextFormatting.hasMeaningfulFormatting(plain))
    }

    func testMeaningfulFormattingKeepsNondefaultParagraphDetails() {
        let value = NSMutableAttributedString(string: "spaced")
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        value.addAttributes([
            .font: RichTextFormatting.defaultFont,
            .foregroundColor: RichTextFormatting.defaultTextColor,
            .paragraphStyle: style
        ], range: NSRange(location: 0, length: value.length))

        XCTAssertTrue(RichTextFormatting.hasMeaningfulFormatting(value))
    }

    func testFormattingSurvivesRTFRoundTrip() throws {
        let value = NSMutableAttributedString(string: "formatted")
        let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let full = NSRange(location: 0, length: value.length)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        value.addAttributes([
            .font: bold,
            .foregroundColor: NSColor.systemPurple,
            .paragraphStyle: style
        ], range: full)

        let data = try XCTUnwrap(value.rtf(from: full))
        let decoded = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )

        XCTAssertEqual(decoded.string, value.string)
        let font = try XCTUnwrap(decoded.attribute(.font, at: 0,
                                                   effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let paragraph = try XCTUnwrap(decoded.attribute(.paragraphStyle, at: 0,
                                                        effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .right)
    }
}
