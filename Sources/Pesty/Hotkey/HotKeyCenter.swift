import AppKit
import Carbon.HIToolbox

private enum HotKeySlot: UInt32 {
    case main = 1
    case pasteStackNext = 2
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Fires for the main show/hide hotkey.
    var onTrigger: (() -> Void)?
    /// Fires for the "paste next stack item" hotkey.
    var onPasteStackTrigger: (() -> Void)?

    private var hotKeyRefs: [HotKeySlot: EventHotKeyRef] = [:]
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
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return noErr }
            DispatchQueue.main.async {
                switch hkID.id {
                case HotKeySlot.main.rawValue: HotKeyCenter.shared.onTrigger?()
                case HotKeySlot.pasteStackNext.rawValue: HotKeyCenter.shared.onPasteStackTrigger?()
                default: break
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Re-registers both global hotkeys.
    ///
    /// The old registration has to be released before the new one can take the same
    /// combination, so a failed `RegisterEventHotKey` leaves the app with no hotkey at
    /// all. That is unrecoverable without a relaunch, and it is one of the ways the bar
    /// "stops opening" (issue #64). Another process can hold the combination briefly
    /// during login or a display change, so retry a few times before giving up, and put
    /// the old registration back if the new one will not take.
    func reload() {
        reload(slot: .main,
               keyCode: Settings.shared.hotkeyKeyCode,
               modifiers: Settings.shared.hotkeyModifiers,
               enabled: true)
        // Paste Stacks off means: no capture, no hotkey - the second hotkey
        // only ever occupies its combination while the feature is enabled.
        reload(slot: .pasteStackNext,
               keyCode: Settings.shared.sequenceHotkeyKeyCode,
               modifiers: Settings.shared.sequenceHotkeyModifiers,
               enabled: Settings.shared.pasteStacksEnabled)
    }

    private func reload(slot: HotKeySlot, keyCode: Int, modifiers: Int, enabled: Bool) {
        let previous = hotKeyRefs[slot]
        unregister(slot: slot)

        guard enabled, keyCode != 0 else { return }
        let code = UInt32(keyCode)
        let mods = UInt32(modifiers)

        if register(slot: slot, keyCode: code, modifiers: mods) { return }

        // Put the old one back so the user is never left without a hotkey, then retry.
        hotKeyRefs[slot] = previous
        retryRegister(slot: slot, keyCode: code, modifiers: mods, attemptsLeft: 5)
    }

    private func register(slot: HotKeySlot, keyCode: UInt32, modifiers: UInt32) -> Bool {
        let id = EventHotKeyID(signature: signature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
        else { return false }
        hotKeyRefs[slot] = ref
        return true
    }

    private func retryRegister(slot: HotKeySlot, keyCode: UInt32, modifiers: UInt32, attemptsLeft: Int) {
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let stale = self.hotKeyRefs[slot]
            self.unregister(slot: slot)
            if self.register(slot: slot, keyCode: keyCode, modifiers: modifiers) { return }
            self.hotKeyRefs[slot] = stale
            self.retryRegister(slot: slot, keyCode: keyCode, modifiers: modifiers, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func unregister(slot: HotKeySlot) {
        if let ref = hotKeyRefs[slot] { UnregisterEventHotKey(ref); hotKeyRefs[slot] = nil }
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
