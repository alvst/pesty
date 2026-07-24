import AppKit

/// Native modal editing for a clip's payload, separate from the card title.
/// Persistence and pasteboard updates stay in AppController and ClipboardStore.
@MainActor
enum ClipEditor {
    enum Edit {
        case text(String, richTextData: Data?)
        case color(String)
    }

    static func run(for item: ClipItem, launchWritingTools: Bool = false) -> Edit? {
        switch item.type {
        case .text, .richText, .link:
            return editText(item, launchWritingTools: launchWritingTools)
        case .color:
            return editColor(item)
        case .image, .file:
            showUnsupportedEditor(for: item)
            return nil
        }
    }

    private static func editText(_ item: ClipItem, launchWritingTools: Bool) -> Edit? {
        let isRichText = item.type == .richText
        let alert = NSAlert()
        alert.messageText = "Edit \(item.type.label)"
        alert.informativeText = isRichText
            ? "Edit this saved clip. Its rich-text formatting is preserved when possible."
            : "Edit this saved clip's contents."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 430, height: 220))
        textView.isRichText = isRichText
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainer?.containerSize = NSSize(width: 430, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
        }

        if isRichText,
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

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 220))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView

        if launchWritingTools {
            DispatchQueue.main.async {
                guard #available(macOS 15.2, *),
                      NSWritingToolsCoordinator.isWritingToolsAvailable else { return }
                alert.window.makeFirstResponder(textView)
                textView.showWritingTools(nil)
            }
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showEmptyTextWarning()
            return nil
        }

        let range = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        let richTextData = isRichText ? textView.rtf(from: range) : nil
        return .text(text, richTextData: richTextData)
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

    private static func showEmptyTextWarning() {
        let alert = NSAlert()
        alert.messageText = "Clip content can't be empty"
        alert.informativeText = "Enter some text before saving this clip."
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
