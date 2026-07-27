import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onTrigger: (() -> Void)?
    var onSequenceTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var sequenceHotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x50535459

    private init() {}

    func start() {
        installHandlerIfNeeded()
        reload()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &id)
            // Carbon delivers application hot-key events from the main event
            // loop. Handle that path synchronously so the panel is key and
            // its local key monitor is installed before the next key event
            // (for example, an immediately following Right Arrow) arrives.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    if id.id == 2 {
                        HotKeyCenter.shared.onSequenceTrigger?()
                    } else {
                        HotKeyCenter.shared.onTrigger?()
                    }
                }
            } else {
                // Keep a safe fallback if Carbon ever invokes this handler
                // from a non-main thread.
                DispatchQueue.main.async {
                    if id.id == 2 {
                        HotKeyCenter.shared.onSequenceTrigger?()
                    } else {
                        HotKeyCenter.shared.onTrigger?()
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    func reload() {
        unregister()
        hotKeyRef = register(keyCode: Settings.shared.hotkeyKeyCode,
                             modifiers: Settings.shared.hotkeyModifiers,
                             id: 1)
        sequenceHotKeyRef = register(keyCode: Settings.shared.sequenceHotkeyKeyCode,
                                     modifiers: Settings.shared.sequenceHotkeyModifiers,
                                     id: 2)
    }

    private func register(keyCode: Int, modifiers: Int, id: UInt32) -> EventHotKeyRef? {
        guard keyCode != 0 else { return nil }
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    private func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = sequenceHotKeyRef { UnregisterEventHotKey(ref); sequenceHotKeyRef = nil }
    }

    static func describe(keyCode: Int, modifiers: Int) -> String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey  != 0 { s += "⌥" }
        if modifiers & shiftKey   != 0 { s += "⇧" }
        if modifiers & cmdKey     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: Int) -> String {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋",
            kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/"
        ]
        return map[keyCode] ?? "?"
    }
}
