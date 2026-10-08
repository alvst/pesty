import SwiftUI
import AppKit
import Carbon.HIToolbox

struct HotkeyRecorderView: View {
    enum Shortcut: Equatable { case main, sequence }

    @Binding private var keyCode: Int
    @Binding private var modifiers: Int
    private let shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var previousKeyCode = 0
    @State private var previousModifiers = 0

    init(keyCode: Binding<Int>, modifiers: Binding<Int>, shortcut: Shortcut) {
        _keyCode = keyCode
        _modifiers = modifiers
        self.shortcut = shortcut
    }

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : HotKeyCenter.describe(keyCode: keyCode, modifiers: modifiers))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(minWidth: 90)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(recording ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.3))
                )
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
    }

    private func start() {
        previousKeyCode = keyCode
        previousModifiers = modifiers
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else { return event }
            let mods = carbonModifiers(from: event.modifierFlags)
            if mods & (cmdKey | controlKey | optionKey) == 0 {
                NSSound.beep(); return nil
            }
            let otherKeyCode = shortcut == .main
                ? Settings.shared.sequenceHotkeyKeyCode : Settings.shared.hotkeyKeyCode
            let otherModifiers = shortcut == .main
                ? Settings.shared.sequenceHotkeyModifiers : Settings.shared.hotkeyModifiers
            if (shortcut == .sequence || Settings.shared.pasteStacksEnabled),
               Int(event.keyCode) == otherKeyCode, mods == otherModifiers {
                NSSound.beep(); stop(); return nil
            }
            keyCode = Int(event.keyCode)
            modifiers = mods
            // Carbon can reject a combination without producing any visible
            // error. Give the user their working shortcut back instead of
            // persisting a shortcut that silently does nothing.
            DispatchQueue.main.async {
                let registered = shortcut == .main
                    ? HotKeyCenter.shared.isMainHotKeyRegistered
                    : HotKeyCenter.shared.isSequenceHotKeyRegistered
                if !registered {
                    keyCode = previousKeyCode
                    modifiers = previousModifiers
                    NSSound.beep()
                }
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.shift)   { m |= shiftKey }
        if flags.contains(.option)  { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        return m
    }
}
