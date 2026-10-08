import AppKit
import SwiftUI

/// Search becomes a keyboard target only through an explicit search action or
/// a click. SwiftUI may update the previous expanded view while reopening the
/// panel, so visibility alone cannot decide initial keyboard ownership.
final class BarSearchTextField: NSTextField {
    var allowsKeyboardFocus = false

    override var acceptsFirstResponder: Bool {
        allowsKeyboardFocus && super.acceptsFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        allowsKeyboardFocus = true
        super.mouseDown(with: event)
    }
}

/// Keeps the Paste Bar's native search field reachable while SwiftUI renders
/// it at a compact width. The local key monitor can therefore transfer first
/// responder synchronously and let the triggering key reach AppKit normally.
@MainActor
final class BarSearchFieldBridge {
    weak var field: BarSearchTextField?

    func install(_ field: BarSearchTextField) {
        self.field = field
    }

    func uninstall(_ field: BarSearchTextField) {
        if self.field === field { self.field = nil }
    }

    @discardableResult
    func focusAtEnd() -> Bool {
        guard let field,
              let window = field.window else { return false }
        // Type-to-search arrives before SwiftUI expands the compact field.
        // Allow focus synchronously so the first character reaches AppKit's
        // field editor in this same event dispatch.
        let allowedKeyboardFocus = field.allowsKeyboardFocus
        field.allowsKeyboardFocus = true
        guard window.makeFirstResponder(field) else {
            field.allowsKeyboardFocus = allowedKeyboardFocus
            return false
        }
        if let editor = field.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
        return true
    }

    func resign() {
        guard let field,
              let window = field.window,
              let editor = field.currentEditor(),
              window.firstResponder === editor else { return }
        window.makeFirstResponder(nil)
    }

    func resetForPresentation() {
        // Keep this independent of SwiftUI's previous expanded layout.
        field?.allowsKeyboardFocus = false
        resign()
    }

    func ownsFirstResponder(in window: NSWindow?) -> Bool {
        guard let window,
              let field,
              let editor = field.currentEditor() else { return false }
        return window.firstResponder === editor
    }
}

struct NativeBarSearchField: NSViewRepresentable {
    @Binding var text: String
    let bridge: BarSearchFieldBridge
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> BarSearchTextField {
        let field = BarSearchTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: 13, weight: .medium)
        // The bar follows the system appearance. A fixed dark ink is readable
        // on its light glass but disappears when the same field turns dark.
        field.textColor = .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bridge.install(field)
        return field
    }

    func updateNSView(_ field: BarSearchTextField, context: Context) {
        context.coordinator.parent = self
        bridge.install(field)
        // Keep an already-active field editor in sync when macOS changes the
        // appearance while the bar is open.
        field.textColor = .labelColor
        (field.currentEditor() as? NSTextView)?.textColor = .labelColor
        // Reassigning an equal value resets the native caret and selection.
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: BarSearchTextField, coordinator: Coordinator) {
        coordinator.parent.bridge.uninstall(field)
        field.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeBarSearchField

        init(parent: NativeBarSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                (field.currentEditor() as? NSTextView)?.textColor = .labelColor
            }
            parent.onBegin()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEnd()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let value = field.stringValue
            guard parent.text != value else { return }
            parent.text = value
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }

            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
