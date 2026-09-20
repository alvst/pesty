import AppKit

/// Edits a clip's payload and its optional card title together. Text editing
/// is intentionally a dedicated surface, rather than an alert, so long
/// clipboard entries remain comfortable to read and format.
@MainActor
enum ClipEditor {
    enum Edit {
        /// `title` is the card's optional display name. `nil` means the clip
        /// has no title — an emptied field clears one rather than leaving the
        /// old value in place.
        case text(String, richTextData: Data?, title: String?, bodyChanged: Bool)
        case color(String)
    }

    static func run(for item: ClipItem, launchWritingTools: Bool = false) -> Edit? {
        NSApp.activate(ignoringOtherApps: true)
        switch item.type {
        case .text, .richText, .link:
            return TextClipEditorController(item: item,
                                            launchWritingTools: launchWritingTools).run()
        case .color:
            return editColor(item)
        case .image, .file:
            showUnsupportedEditor(for: item)
            return nil
        }
    }

    private static func editColor(_ item: ClipItem) -> Edit? {
        let alert = NSAlert()
        alert.messageText = "Edit Color"
        alert.informativeText = "Choose the color stored in this saved clip."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let color = item.colorHex.flatMap(NSColor.init(hex:)) ?? .black
        let accessory = ColorEditorAccessoryView(color: color)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return .color(accessory.selectedHex)
    }

    private static func showUnsupportedEditor(for item: ClipItem) {
        let alert = NSAlert()
        alert.messageText = "This clip can't be edited"
        alert.informativeText = "Pesty can edit text, rich text, links, and colors. \(item.type.label) clips are kept as-is."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
enum ClipEditorToolbar {
    static let buttonWidth: CGFloat = 38
    static let buttonHeight: CGFloat = 32

    static func button(symbol: String,
                       label: String,
                       tooltip: String,
                       target: AnyObject?,
                       action: Selector?,
                       key: String = "",
                       toggles: Bool = false) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .rounded
        button.setButtonType(toggles ? .pushOnPushOff : .momentaryPushIn)
        // Leave the bezel and content tints to AppKit, as with the adjacent
        // Formatting popup. Custom bezel colors plus attributed label ink
        // produced black-on-dark controls in the editor's sheet material.
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        button.image?.isTemplate = true
        button.title = ""
        button.imagePosition = .imageOnly
        button.target = target
        button.action = action
        button.toolTip = tooltip
        button.setAccessibilityLabel(label)
        if tooltip != label { button.setAccessibilityHelp(tooltip) }
        if !key.isEmpty {
            button.keyEquivalent = key
            button.keyEquivalentModifierMask = .command
        }
        button.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: buttonHeight).isActive = true
        return button
    }
}

@MainActor
private final class TextClipEditorController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private let item: ClipItem
    private let launchWritingTools: Bool
    private let panel: NSPanel
    private let textView = NSTextView()
    private var initialBody = NSAttributedString(string: "")
    private let titleField = NSTextField()
    private let saveButton = NSButton()
    private let statsLabel = NSTextField(labelWithString: "")
    private var result: ClipEditor.Edit?
    private weak var boldButton: NSButton?
    private weak var italicButton: NSButton?
    private weak var underlineButton: NSButton?
    private weak var strikethroughButton: NSButton?
    private var fontPanelOriginalLevel: NSWindow.Level?
    private var fontPanelOriginalWorksWhenModal: Bool?
    private weak var fontManagerOriginalTarget: AnyObject?
    private var fontManagerOriginalAction: Selector?
    private var colorPanelOriginalLevel: NSWindow.Level?
    private var colorPanelOriginalWorksWhenModal: Bool?
    private var colorPanelOriginalShowsAlpha: Bool?

    private enum ColorTarget {
        case text
        case highlight

        var attribute: NSAttributedString.Key {
            switch self {
            case .text: .foregroundColor
            case .highlight: .backgroundColor
            }
        }
    }

    private var colorTarget: ColorTarget = .text

    init(item: ClipItem, launchWritingTools: Bool) {
        self.item = item
        self.launchWritingTools = launchWritingTools
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        configureEditor()
        buildInterface()
        loadInitialContent()
        updateStats()
        updateFormattingControls()
    }

    func run() -> ClipEditor.Edit? {
        defer {
            // Shared AppKit formatting panels outlive this controller. Always
            // release their targets and restore their window configuration,
            // including if modal execution exits through an unusual path.
            closeFormattingPanels()
            panel.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)

        if launchWritingTools {
            // Keep the modal editor alive through the next run-loop turn so
            // Writing Tools is requested only after the text view is key.
            DispatchQueue.main.async { self.showWritingTools() }
        }

        NSApp.runModal(for: panel)
        return result
    }

    func textDidChange(_ notification: Notification) {
        updateStats()
        updateFormattingControls()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateFormattingControls()
    }

    func textViewDidChangeTypingAttributes(_ notification: Notification) {
        updateFormattingControls()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(with: nil)
        return false
    }

    private func configurePanel() {
        panel.delegate = self
        panel.title = "Edit \(item.type.label)"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // A utility panel hides itself when the app deactivates. Clicking
        // another app mid-edit would take the editor off screen while
        // `runModal` kept spinning, leaving no way back to the open session.
        panel.hidesOnDeactivate = false
        // The Paste Bar deliberately sits at the modal-panel level so it can
        // stay visible without activating Pesty. The editor must clear that
        // surface while it owns focus.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
        panel.minSize = NSSize(width: 520, height: 380)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func configureEditor() {
        textView.delegate = self
        textView.frame = NSRect(x: 0, y: 0, width: 720, height: 420)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.usesFontPanel = true
        textView.font = .systemFont(ofSize: 17)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0,
                                                        height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
        }
    }

    private func buildInterface() {
        let effect = NSVisualEffectView()
        // A sheet material keeps the toolbar legible regardless of what is
        // behind Pesty. The HUD/behind-window combination made the controls
        // inherit a low-contrast blue treatment.
        effect.material = .sheet
        effect.blendingMode = .withinWindow
        effect.state = .active
        panel.contentView = effect

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.title = "Save"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        // ⌘Return, not Return: this is a multi-line editor, and a plain
        // Return default button claims the key before the text view can
        // insert a newline with it. The button keeps its accent fill, so it
        // still reads as the default action without owning the key.
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.toolTip = "Save (⌘↩)"
        saveButton.bezelColor = .controlAccentColor
        saveButton.contentTintColor = .white
        saveButton.attributedTitle = NSAttributedString(
            string: "Save",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )

        let bold = toolbarSymbolButton(symbol: "bold", label: "Bold", tooltip: "Bold (⌘B)",
                                       action: #selector(toggleBold), key: "b", toggles: true)
        let italic = toolbarSymbolButton(symbol: "italic", label: "Italic", tooltip: "Italic (⌘I)",
                                         action: #selector(toggleItalic), key: "i", toggles: true)
        let underline = toolbarSymbolButton(symbol: "underline", label: "Underline",
                                            tooltip: "Underline (⌘U)",
                                            action: #selector(toggleUnderline), key: "u", toggles: true)
        let strikethrough = toolbarSymbolButton(symbol: "strikethrough", label: "Strikethrough",
                                                tooltip: "Strikethrough",
                                                action: #selector(toggleStrikethrough), toggles: true)
        boldButton = bold
        italicButton = italic
        underlineButton = underline
        strikethroughButton = strikethrough

        let formatting = NSStackView(views: [
            bold, italic, underline, strikethrough, formattingMenuButton()
        ])
        formatting.orientation = .horizontal
        formatting.spacing = 6

        if writingToolsAvailable {
            formatting.addArrangedSubview(
                toolbarSymbolButton(symbol: "pencil.and.scribble",
                                    label: "Writing Tools",
                                    tooltip: "Writing Tools",
                                    action: #selector(showWritingTools))
            )
        }

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        let leadingSpacer = flexibleSpacer()
        let trailingSpacer = flexibleSpacer()
        toolbar.addArrangedSubview(cancelButton)
        toolbar.addArrangedSubview(leadingSpacer)
        toolbar.addArrangedSubview(formatting)
        toolbar.addArrangedSubview(trailingSpacer)
        toolbar.addArrangedSubview(saveButton)

        titleField.placeholderString = "Title (optional)"
        titleField.stringValue = item.customTitle ?? ""
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.bezelStyle = .roundedBezel
        titleField.isBezeled = true
        titleField.focusRingType = .default
        titleField.setAccessibilityLabel("Card title")
        titleField.toolTip = "Shown on the clip's card in place of its contents"
        // Return in a single-line field commits it; here that means moving on
        // to the body rather than saving, so the whole panel treats Return as
        // "keep going" and ⌘Return as "done".
        titleField.target = self
        titleField.action = #selector(focusBody)
        titleField.nextKeyView = textView

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .lineBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10

        statsLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.lineBreakMode = .byTruncatingTail

        for view in [toolbar, titleField, scrollView, statsLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16),

            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),

            titleField.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titleField.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            titleField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: statsLabel.topAnchor, constant: -10),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),

            statsLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            statsLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            statsLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statsLabel.heightAnchor.constraint(equalToConstant: 18)
        ])

        leadingSpacer.widthAnchor.constraint(equalTo: trailingSpacer.widthAnchor).isActive = true
        updateFormattingControls()
    }

    private func loadInitialContent() {
        if item.type == .richText,
           let data = item.rtfData,
           let value = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            textView.textStorage?.setAttributedString(value)
        } else {
            textView.string = item.text ?? ""
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let storage = textView.textStorage {
            initialBody = NSAttributedString(attributedString: storage)
        }
    }

    private var writingToolsAvailable: Bool {
        guard #available(macOS 15.2, *) else { return false }
        return NSWritingToolsCoordinator.isWritingToolsAvailable
    }

    private func toolbarSymbolButton(symbol: String,
                                     label: String,
                                     tooltip: String,
                                     action: Selector,
                                     key: String = "",
                                     toggles: Bool = false) -> NSButton {
        ClipEditorToolbar.button(symbol: symbol, label: label, tooltip: tooltip,
                                 target: self, action: action, key: key, toggles: toggles)
    }

    /// Keeps the common character styles one click away while grouping the
    /// less-frequent, full rich-text controls into a compact native menu. That
    /// still fits when the editor is resized to its 520-point minimum width.
    private func formattingMenuButton() -> NSPopUpButton {
        let menu = NSMenu(title: "Formatting")
        let label = NSMenuItem(title: "Formatting", action: nil, keyEquivalent: "")
        label.image = toolbarSymbol(named: "textformat")
        menu.addItem(label)

        menu.addItem(menuItem("Fonts & Size…", action: #selector(showFontPanel),
                              symbol: "textformat.size"))
        menu.addItem(menuItem("Text Color…", action: #selector(showTextColorPanel),
                              symbol: "paintpalette"))
        menu.addItem(menuItem("Highlight Color…", action: #selector(showHighlightColorPanel),
                              symbol: "highlighter"))
        menu.addItem(menuItem("Remove Highlight", action: #selector(removeHighlight),
                              symbol: "eraser"))

        let sizeMenu = NSMenu(title: "Font Size")
        sizeMenu.addItem(menuItem("Increase", action: #selector(increaseFontSize),
                                  symbol: "plus"))
        sizeMenu.addItem(menuItem("Decrease", action: #selector(decreaseFontSize),
                                  symbol: "minus"))
        sizeMenu.addItem(menuItem("Reset to 17 pt", action: #selector(resetFontSize),
                                  symbol: "arrow.counterclockwise"))
        let sizeItem = NSMenuItem(title: "Font Size", action: nil, keyEquivalent: "")
        sizeItem.image = toolbarSymbol(named: "textformat.size")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let alignmentMenu = NSMenu(title: "Alignment")
        alignmentMenu.addItem(menuItem("Left", action: #selector(alignLeft),
                                       symbol: "text.alignleft"))
        alignmentMenu.addItem(menuItem("Center", action: #selector(alignCenter),
                                       symbol: "text.aligncenter"))
        alignmentMenu.addItem(menuItem("Right", action: #selector(alignRight),
                                       symbol: "text.alignright"))
        alignmentMenu.addItem(menuItem("Justified", action: #selector(alignJustified),
                                       symbol: "text.justify"))
        let alignmentItem = NSMenuItem(title: "Alignment", action: nil, keyEquivalent: "")
        alignmentItem.image = toolbarSymbol(named: "text.alignleft")
        alignmentItem.submenu = alignmentMenu
        menu.addItem(alignmentItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("Clear Formatting", action: #selector(clearFormatting),
                              symbol: "eraser.fill"))

        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.menu = menu
        button.selectItem(at: 0)
        button.bezelStyle = .rounded
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.imagePosition = .imageOnly
        button.toolTip = "More Formatting"
        button.setAccessibilityLabel("More Formatting")
        button.widthAnchor.constraint(equalToConstant: ClipEditorToolbar.buttonWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: ClipEditorToolbar.buttonHeight).isActive = true
        return button
    }

    private func menuItem(_ title: String,
                          action: Selector,
                          symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = toolbarSymbol(named: symbol)
        return item
    }

    private func toolbarSymbol(named name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    @objc private func focusBody() {
        panel.makeFirstResponder(textView)
    }

    @objc private func cancel() {
        finish(with: nil)
    }

    @objc private func save() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let range = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        let shouldSaveRichText = textView.textStorage.map {
            RichTextFormatting.hasMeaningfulFormatting($0)
        } ?? false
        let richTextData = shouldSaveRichText ? textView.rtf(from: range) : nil
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyChanged = textView.textStorage.map { !initialBody.isEqual(to: $0) } ?? false
        finish(with: .text(text, richTextData: richTextData,
                           title: title.isEmpty ? nil : title,
                           bodyChanged: bodyChanged))
    }

    @objc private func showWritingTools() {
        guard #available(macOS 15.2, *), NSWritingToolsCoordinator.isWritingToolsAvailable else { return }
        panel.makeFirstResponder(textView)
        textView.showWritingTools(nil)
    }

    @objc private func showFontPanel() {
        panel.makeFirstResponder(textView)
        let manager = NSFontManager.shared
        guard let fontPanel = manager.fontPanel(true) else { return }
        if fontPanelOriginalLevel == nil {
            fontPanelOriginalLevel = fontPanel.level
            fontPanelOriginalWorksWhenModal = fontPanel.worksWhenModal
            fontManagerOriginalTarget = manager.target as AnyObject?
            fontManagerOriginalAction = manager.action
        }
        synchronizeFontPanel()
        fontPanel.worksWhenModal = true
        fontPanel.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        fontPanel.orderFront(nil)
    }

    @objc private func changeFont(_ manager: NSFontManager) {
        applyFontTransform { manager.convert($0) }
    }

    @objc private func showTextColorPanel() {
        showColorPanel(for: .text)
    }

    @objc private func showHighlightColorPanel() {
        showColorPanel(for: .highlight)
    }

    private func showColorPanel(for target: ColorTarget) {
        panel.makeFirstResponder(textView)
        colorTarget = target
        let colorPanel = NSColorPanel.shared
        if colorPanelOriginalLevel == nil {
            colorPanelOriginalLevel = colorPanel.level
            colorPanelOriginalWorksWhenModal = colorPanel.worksWhenModal
            colorPanelOriginalShowsAlpha = colorPanel.showsAlpha
        }
        // Assigning `color` sends the shared panel's current action. Detach
        // first so merely opening the picker never flattens the selection to
        // its first color (or applies the default highlight).
        synchronizeColorPanel()
        colorPanel.showsAlpha = true
        colorPanel.worksWhenModal = true
        colorPanel.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        colorPanel.orderFront(nil)
    }

    @objc private func changeColor(_ sender: NSColorPanel) {
        applySelectedAttribute(colorTarget.attribute, value: sender.color, restoreEditorFocus: false)
    }

    @objc private func increaseFontSize() {
        resizeFont(by: 1)
    }

    @objc private func decreaseFontSize() {
        resizeFont(by: -1)
    }

    @objc private func resetFontSize() {
        applyFontTransform {
            NSFontManager.shared.convert($0, toSize: RichTextFormatting.defaultFontSize)
        }
    }

    private func resizeFont(by delta: CGFloat) {
        applyFontTransform { font in
            let size = min(288, max(6, font.pointSize + delta))
            return NSFontManager.shared.convert(font, toSize: size)
        }
    }

    @objc private func alignLeft() { applyAlignment(.left) }
    @objc private func alignCenter() { applyAlignment(.center) }
    @objc private func alignRight() { applyAlignment(.right) }
    @objc private func alignJustified() { applyAlignment(.justified) }

    private func applyAlignment(_ alignment: NSTextAlignment) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        if storage.length == 0 {
            applyTypingAlignment(alignment)
            return
        }

        let paragraphRange = RichTextFormatting.paragraphRange(for: selection, in: storage)
        // A caret immediately after a trailing newline belongs to a real but
        // empty paragraph. It has no storage range yet, so configure the
        // typing paragraph style that its future characters will inherit.
        guard paragraphRange.length > 0 else {
            applyTypingAlignment(alignment)
            return
        }
        mutateStorage(in: paragraphRange) { storage, _ in
            RichTextFormatting.setAlignment(alignment, in: storage, selection: selection)
        }
        textView.setSelectedRange(selection)
    }

    private func applyTypingAlignment(_ alignment: NSTextAlignment) {
        var attributes = textView.typingAttributes
        let style = ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                     as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.alignment = alignment
        attributes[.paragraphStyle] = style
        textView.typingAttributes = attributes
        updateFormattingControls()
        panel.makeFirstResponder(textView)
    }

    @objc private func removeHighlight() {
        removeSelectedAttribute(.backgroundColor)
    }

    @objc private func clearFormatting() {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard storage.length > 0 else {
            textView.typingAttributes = [
                .font: RichTextFormatting.defaultFont,
                .foregroundColor: RichTextFormatting.defaultTextColor
            ]
            updateFormattingControls()
            panel.makeFirstResponder(textView)
            return
        }

        // With no selection, clearing the entire body provides an intentional
        // one-click escape from copied Terminal/web styling. A nonempty
        // selection remains precisely scoped.
        let target = selection.length > 0
            ? selection
            : NSRange(location: 0, length: storage.length)
        mutateStorage(in: target) { storage, range in
            RichTextFormatting.clear(in: storage, range: range)
        }
        if selection.length == 0 {
            textView.typingAttributes = [
                .font: RichTextFormatting.defaultFont,
                .foregroundColor: RichTextFormatting.defaultTextColor
            ]
        }
        textView.setSelectedRange(selection)
    }

    @objc private func toggleBold() {
        toggleFontTrait(.boldFontMask)
    }

    @objc private func toggleItalic() {
        toggleFontTrait(.italicFontMask)
    }

    @objc private func toggleUnderline() {
        toggleDecoration(.underlineStyle, enabledValue: NSUnderlineStyle.single.rawValue)
    }

    @objc private func toggleStrikethrough() {
        toggleDecoration(.strikethroughStyle, enabledValue: NSUnderlineStyle.single.rawValue)
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            let font = (attributes[.font] as? NSFont) ?? RichTextFormatting.defaultFont
            let isEnabled = NSFontManager.shared.traits(of: font).contains(trait)
            attributes[.font] = isEnabled
                ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(font, toHaveTrait: trait)
            textView.typingAttributes = attributes
            updateFormattingControls()
            panel.makeFirstResponder(textView)
            return
        }
        mutateStorage(in: range) { storage, safeRange in
            RichTextFormatting.toggleFontTrait(trait, in: storage, range: safeRange)
        }
    }

    private func toggleDecoration(_ key: NSAttributedString.Key, enabledValue: Int) {
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            if RichTextFormatting.integerValue(attributes[key]) == 0 {
                attributes[key] = enabledValue
            } else {
                attributes.removeValue(forKey: key)
            }
            textView.typingAttributes = attributes
            updateFormattingControls()
            panel.makeFirstResponder(textView)
            return
        }
        mutateStorage(in: range) { storage, safeRange in
            RichTextFormatting.toggleDecoration(key, enabledValue: enabledValue,
                                                in: storage, range: safeRange)
        }
    }

    private func applyFontTransform(_ transform: @escaping (NSFont) -> NSFont) {
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            let font = (attributes[.font] as? NSFont) ?? RichTextFormatting.defaultFont
            attributes[.font] = transform(font)
            textView.typingAttributes = attributes
            updateFormattingControls()
            panel.makeFirstResponder(textView)
            return
        }
        mutateStorage(in: range) { storage, safeRange in
            RichTextFormatting.transformFonts(in: storage, range: safeRange,
                                              transform: transform)
        }
    }

    private func applySelectedAttribute(_ key: NSAttributedString.Key,
                                        value: Any,
                                        restoreEditorFocus: Bool = true) {
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            attributes[key] = value
            textView.typingAttributes = attributes
            updateFormattingControls()
            if restoreEditorFocus { panel.makeFirstResponder(textView) }
            return
        }
        mutateStorage(in: range, restoreEditorFocus: restoreEditorFocus) { storage, safeRange in
            RichTextFormatting.setAttribute(key, value: value, in: storage, range: safeRange)
        }
    }

    private func removeSelectedAttribute(_ key: NSAttributedString.Key) {
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            attributes.removeValue(forKey: key)
            textView.typingAttributes = attributes
            updateFormattingControls()
            panel.makeFirstResponder(textView)
            return
        }
        mutateStorage(in: range) { storage, safeRange in
            RichTextFormatting.removeAttribute(key, in: storage, range: safeRange)
        }
    }

    private func mutateStorage(in range: NSRange,
                               restoreEditorFocus: Bool = true,
                               mutation: (NSMutableAttributedString, NSRange) -> Void) {
        guard let storage = textView.textStorage else { return }
        let safeRange = RichTextFormatting.clampedRange(range, length: storage.length)
        guard safeRange.length > 0,
              textView.shouldChangeText(in: safeRange, replacementString: nil) else { return }
        mutation(storage, safeRange)
        textView.didChangeText()
        updateFormattingControls()
        if restoreEditorFocus { panel.makeFirstResponder(textView) }
    }

    private func currentFont() -> NSFont {
        let attributes = textView.typingAttributes
        if textView.selectedRange().length == 0,
           let font = attributes[.font] as? NSFont { return font }
        guard let storage = textView.textStorage else { return RichTextFormatting.defaultFont }
        return RichTextFormatting.font(at: textView.selectedRange().location, in: storage)
    }

    private func currentColor(for target: ColorTarget) -> NSColor {
        let range = textView.selectedRange()
        if range.length == 0,
           let color = textView.typingAttributes[target.attribute] as? NSColor { return color }
        if let storage = textView.textStorage, storage.length > 0 {
            let location = min(max(range.location, 0), storage.length - 1)
            if let color = storage.attribute(target.attribute, at: location,
                                             effectiveRange: nil) as? NSColor { return color }
        }
        switch target {
        case .text: return RichTextFormatting.defaultTextColor
        case .highlight: return .yellow.withAlphaComponent(0.45)
        }
    }

    private func updateFormattingControls() {
        defer { synchronizeOpenFormattingPanels() }
        let range = textView.selectedRange()
        guard let storage = textView.textStorage else { return }
        if range.length == 0 {
            let attributes = textView.typingAttributes
            let font = (attributes[.font] as? NSFont) ?? RichTextFormatting.defaultFont
            update(button: boldButton,
                   state: NSFontManager.shared.traits(of: font).contains(.boldFontMask) ? .on : .off)
            update(button: italicButton,
                   state: NSFontManager.shared.traits(of: font).contains(.italicFontMask) ? .on : .off)
            update(button: underlineButton,
                   state: RichTextFormatting.integerValue(attributes[.underlineStyle]) == 0 ? .off : .on)
            update(button: strikethroughButton,
                   state: RichTextFormatting.integerValue(attributes[.strikethroughStyle]) == 0 ? .off : .on)
            return
        }
        update(button: boldButton,
               state: RichTextFormatting.fontTraitState(.boldFontMask, in: storage, range: range))
        update(button: italicButton,
               state: RichTextFormatting.fontTraitState(.italicFontMask, in: storage, range: range))
        update(button: underlineButton,
               state: RichTextFormatting.decorationState(.underlineStyle, in: storage, range: range))
        update(button: strikethroughButton,
               state: RichTextFormatting.decorationState(.strikethroughStyle, in: storage, range: range))
    }

    private func update(button: NSButton?, state: RichTextFormatting.UniformState) {
        guard let button else { return }
        button.allowsMixedState = true
        switch state {
        case .off: button.state = .off
        case .on: button.state = .on
        case .mixed: button.state = .mixed
        }
    }

    private func synchronizeOpenFormattingPanels() {
        if fontPanelOriginalLevel != nil,
           NSFontManager.shared.fontPanel(false)?.isVisible == true {
            synchronizeFontPanel()
        }
        if colorPanelOriginalLevel != nil,
           NSColorPanel.sharedColorPanelExists,
           NSColorPanel.shared.isVisible {
            synchronizeColorPanel()
        }
    }

    private func synchronizeFontPanel() {
        let manager = NSFontManager.shared
        let range = textView.selectedRange()
        // Keep programmatic synchronization from invoking either this
        // editor's action or whichever target owned the shared manager first.
        manager.target = nil
        manager.setSelectedFont(currentFont(), isMultiple: range.length > 0
            && textView.textStorage.map {
                RichTextFormatting.hasMultipleFonts(in: $0, range: range)
            } == true)
        manager.target = self
        manager.action = #selector(changeFont(_:))
    }

    private func synchronizeColorPanel() {
        let colorPanel = NSColorPanel.shared
        // `color` sends the configured action, so synchronization must be
        // inert. Reattach only after the visible color is current.
        colorPanel.setTarget(nil)
        colorPanel.setAction(nil)
        colorPanel.color = currentColor(for: colorTarget)
        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(changeColor(_:)))
    }

    private func updateStats() {
        let text = textView.string
        let characters = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        let characterStat = "\(characters) \(countLabel(characters, singular: "character"))"
        let wordStat = "\(words) \(countLabel(words, singular: "word"))"
        let lineStat = "\(lines) \(countLabel(lines, singular: "line"))"
        statsLabel.stringValue = [characterStat, wordStat, lineStat].joined(separator: "  ·  ")
        let canSave = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        saveButton.isEnabled = canSave
        saveButton.attributedTitle = NSAttributedString(
            string: "Save",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: canSave ? NSColor.white : NSColor.disabledControlTextColor
            ]
        )
    }

    private func countLabel(_ count: Int, singular: String) -> String {
        count == 1 ? singular : "\(singular)s"
    }

    private func finish(with value: ClipEditor.Edit?) {
        closeFormattingPanels()
        result = value
        panel.orderOut(nil)
        NSApp.stopModal()
    }

    private func closeFormattingPanels() {
        let fontManager = NSFontManager.shared
        if let originalLevel = fontPanelOriginalLevel,
           let fontPanel = fontManager.fontPanel(false) {
            fontManager.target = fontManagerOriginalTarget
            if let originalAction = fontManagerOriginalAction {
                fontManager.action = originalAction
            }
            fontPanel.orderOut(nil)
            fontPanel.level = originalLevel
            if let originalWorksWhenModal = fontPanelOriginalWorksWhenModal {
                fontPanel.worksWhenModal = originalWorksWhenModal
            }
        }
        fontPanelOriginalLevel = nil
        fontPanelOriginalWorksWhenModal = nil
        fontManagerOriginalTarget = nil
        fontManagerOriginalAction = nil

        if let originalLevel = colorPanelOriginalLevel {
            // Checking the captured state avoids creating the process-global
            // color panel during ordinary editor sessions that never used it.
            let colorPanel = NSColorPanel.shared
            colorPanel.setTarget(nil)
            colorPanel.setAction(nil)
            colorPanel.orderOut(nil)
            colorPanel.level = originalLevel
            if let originalWorksWhenModal = colorPanelOriginalWorksWhenModal {
                colorPanel.worksWhenModal = originalWorksWhenModal
            }
            if let originalShowsAlpha = colorPanelOriginalShowsAlpha {
                colorPanel.showsAlpha = originalShowsAlpha
            }
        }
        colorPanelOriginalLevel = nil
        colorPanelOriginalWorksWhenModal = nil
        colorPanelOriginalShowsAlpha = nil
    }
}

@MainActor
private final class ColorEditorAccessoryView: NSStackView {
    private let colorWell: NSColorWell
    private let valueLabel: NSTextField

    init(color: NSColor) {
        colorWell = NSColorWell()
        valueLabel = NSTextField(labelWithString: color.hexString)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 32))

        orientation = .horizontal
        alignment = .centerY
        spacing = 10

        let label = NSTextField(labelWithString: "Color:")
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        colorWell.color = color
        colorWell.target = self
        colorWell.action = #selector(colorDidChange)
        colorWell.widthAnchor.constraint(equalToConstant: 42).isActive = true

        addArrangedSubview(label)
        addArrangedSubview(colorWell)
        addArrangedSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var selectedHex: String { colorWell.color.hexString }

    @objc private func colorDidChange() {
        valueLabel.stringValue = selectedHex
    }
}
