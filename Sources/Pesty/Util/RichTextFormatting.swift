import AppKit

/// Pure attributed-string operations shared by the clip editor and its tests.
/// Keeping these mutations out of the modal window controller makes mixed-run
/// behavior, paragraph scoping, and RTF persistence deterministic to verify.
enum RichTextFormatting {
    static let defaultFontSize: CGFloat = 17
    static var defaultFont: NSFont { .systemFont(ofSize: defaultFontSize) }
    static var defaultTextColor: NSColor { .labelColor }

    enum UniformState: Equatable {
        case off
        case on
        case mixed
    }

    static func clampedRange(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let available = max(0, length - location)
        return NSRange(location: location, length: min(max(0, range.length), available))
    }

    static func font(at location: Int,
                     in storage: NSAttributedString,
                     fallback: NSFont = defaultFont) -> NSFont {
        guard storage.length > 0 else { return fallback }
        let safeLocation = min(max(location, 0), storage.length - 1)
        return (storage.attribute(.font, at: safeLocation, effectiveRange: nil) as? NSFont)
            ?? fallback
    }

    static func fontTraitState(_ trait: NSFontTraitMask,
                               in storage: NSAttributedString,
                               range: NSRange,
                               fallback: NSFont = defaultFont) -> UniformState {
        let safeRange = clampedRange(range, length: storage.length)
        guard safeRange.length > 0 else { return .off }

        var hasEnabled = false
        var hasDisabled = false
        storage.enumerateAttribute(.font, in: safeRange) { value, _, _ in
            let font = (value as? NSFont) ?? fallback
            if NSFontManager.shared.traits(of: font).contains(trait) {
                hasEnabled = true
            } else {
                hasDisabled = true
            }
        }
        if hasEnabled && hasDisabled { return .mixed }
        return hasEnabled ? .on : .off
    }

    /// A mixed selection becomes uniformly enabled; a uniformly enabled
    /// selection becomes disabled. This matches native rich-text editors and
    /// avoids deciding the whole range from only its first character.
    @discardableResult
    static func toggleFontTrait(_ trait: NSFontTraitMask,
                                in storage: NSMutableAttributedString,
                                range: NSRange,
                                fallback: NSFont = defaultFont) -> Bool {
        let safeRange = clampedRange(range, length: storage.length)
        guard safeRange.length > 0 else { return false }
        let enablesTrait = fontTraitState(trait, in: storage, range: safeRange,
                                          fallback: fallback) != .on
        transformFonts(in: storage, range: safeRange, fallback: fallback) { font in
            enablesTrait
                ? NSFontManager.shared.convert(font, toHaveTrait: trait)
                : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
        }
        return enablesTrait
    }

    static func transformFonts(in storage: NSMutableAttributedString,
                               range: NSRange,
                               fallback: NSFont = defaultFont,
                               transform: (NSFont) -> NSFont) {
        let safeRange = clampedRange(range, length: storage.length)
        guard safeRange.length > 0 else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: safeRange) { value, subrange, _ in
            storage.addAttribute(.font,
                                 value: transform((value as? NSFont) ?? fallback),
                                 range: subrange)
        }
        storage.endEditing()
    }

    static func decorationState(_ key: NSAttributedString.Key,
                                in storage: NSAttributedString,
                                range: NSRange) -> UniformState {
        let safeRange = clampedRange(range, length: storage.length)
        guard safeRange.length > 0 else { return .off }
        var hasEnabled = false
        var hasDisabled = false
        storage.enumerateAttribute(key, in: safeRange) { value, _, _ in
            if integerValue(value) == 0 { hasDisabled = true } else { hasEnabled = true }
        }
        if hasEnabled && hasDisabled { return .mixed }
        return hasEnabled ? .on : .off
    }

    @discardableResult
    static func toggleDecoration(_ key: NSAttributedString.Key,
                                 enabledValue: Int,
                                 in storage: NSMutableAttributedString,
                                 range: NSRange) -> Bool {
        let safeRange = clampedRange(range, length: storage.length)
        guard safeRange.length > 0 else { return false }
        let enablesDecoration = decorationState(key, in: storage, range: safeRange) != .on
        if enablesDecoration {
            storage.addAttribute(key, value: enabledValue, range: safeRange)
        } else {
            storage.removeAttribute(key, range: safeRange)
        }
        return enablesDecoration
    }

    static func setAttribute(_ key: NSAttributedString.Key,
                             value: Any,
                             in storage: NSMutableAttributedString,
                             range: NSRange) {
        let safeRange = clampedRange(range, length: storage.length)
        guard safeRange.length > 0 else { return }
        storage.addAttribute(key, value: value, range: safeRange)
    }

    static func removeAttribute(_ key: NSAttributedString.Key,
                                in storage: NSMutableAttributedString,
                                range: NSRange) {
        let safeRange = clampedRange(range, length: storage.length)
        guard safeRange.length > 0 else { return }
        storage.removeAttribute(key, range: safeRange)
    }

    static func paragraphRange(for selection: NSRange,
                               in storage: NSAttributedString) -> NSRange {
        guard storage.length > 0 else { return NSRange(location: 0, length: 0) }
        let safeSelection = clampedRange(selection, length: storage.length)
        return (storage.string as NSString).paragraphRange(for: safeSelection)
    }

    static func setAlignment(_ alignment: NSTextAlignment,
                             in storage: NSMutableAttributedString,
                             selection: NSRange) {
        let range = paragraphRange(for: selection, in: storage)
        guard range.length > 0 else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy()
                         as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        storage.endEditing()
    }

    /// Replaces every attribute in scope, including copied background colors,
    /// links, shadows, baseline offsets, and decorations. The string itself is
    /// untouched.
    static func clear(in storage: NSMutableAttributedString,
                      range: NSRange,
                      font: NSFont = defaultFont,
                      textColor: NSColor = defaultTextColor) {
        let safeRange = clampedRange(range, length: storage.length)
        guard safeRange.length > 0 else { return }
        storage.setAttributes([.font: font, .foregroundColor: textColor], range: safeRange)
    }

    static func hasMultipleFonts(in storage: NSAttributedString,
                                 range: NSRange,
                                 fallback: NSFont = defaultFont) -> Bool {
        let safeRange = clampedRange(range, length: storage.length)
        guard safeRange.length > 0 else { return false }
        var first: NSFont?
        var multiple = false
        storage.enumerateAttribute(.font, in: safeRange) { value, _, stop in
            let font = (value as? NSFont) ?? fallback
            if let first, !first.isEqual(font) {
                multiple = true
                stop.pointee = true
            } else {
                first = font
            }
        }
        return multiple
    }

    /// Plain clips already carry the editor's base font/color in NSTextStorage.
    /// Save RTF only when content contains something beyond those defaults, so
    /// rich paste is retained while a no-op formatting click does not silently
    /// convert ordinary text.
    static func hasMeaningfulFormatting(_ storage: NSAttributedString,
                                        defaultFont: NSFont = defaultFont,
                                        defaultTextColor: NSColor = defaultTextColor) -> Bool {
        guard storage.length > 0 else { return false }
        var meaningful = false
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) {
            attributes, _, stop in
            for (key, value) in attributes {
                switch key {
                case .font:
                    guard let font = value as? NSFont, font.isEqual(defaultFont) else {
                        meaningful = true; break
                    }
                case .foregroundColor:
                    guard let color = value as? NSColor, color.isEqual(defaultTextColor) else {
                        meaningful = true; break
                    }
                case .paragraphStyle:
                    guard let style = value as? NSParagraphStyle,
                          isDefaultParagraphStyle(style) else {
                        meaningful = true; break
                    }
                default:
                    meaningful = true
                }
                if meaningful { break }
            }
            if meaningful { stop.pointee = true }
        }
        return meaningful
    }

    static func integerValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let integer = value as? Int { return integer }
        return 0
    }

    private static func isDefaultParagraphStyle(_ style: NSParagraphStyle) -> Bool {
        style.isEqual(NSParagraphStyle.default)
    }
}
