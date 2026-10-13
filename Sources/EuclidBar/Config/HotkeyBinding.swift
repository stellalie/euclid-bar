import AppKit
import Carbon.HIToolbox
import EuclidCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    @MainActor static let togglePanel = Self("togglePanel", default: .init(.space, modifiers: [.option]))
}

enum HotkeyBinding {
    /// Apply a config hotkey. The config wins over anything set in the app.
    @MainActor static func apply(_ spec: HotkeySpec) {
        guard let code = keyCode(spec.key) else { return }
        var mods: NSEvent.ModifierFlags = []
        if spec.modifiers.contains(.command) { mods.insert(.command) }
        if spec.modifiers.contains(.option) { mods.insert(.option) }
        if spec.modifiers.contains(.control) { mods.insert(.control) }
        if spec.modifiers.contains(.shift) { mods.insert(.shift) }
        let shortcut = KeyboardShortcuts.Shortcut(KeyboardShortcuts.Key(rawValue: code), modifiers: mods)
        if KeyboardShortcuts.getShortcut(for: .togglePanel) != shortcut {
            KeyboardShortcuts.setShortcut(shortcut, for: .togglePanel)
        }
    }

    /// Physical (ANSI layout) key codes.
    static func keyCode(_ key: String) -> Int? {
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                       kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                       kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                       kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        switch key {
        case "space": return kVK_Space
        case "return": return kVK_Return
        case "tab": return kVK_Tab
        default: break
        }
        if key.count == 1, let c = key.unicodeScalars.first {
            if ("a"..."z").contains(c) { return letters[Int(c.value - 97)] }
            if ("0"..."9").contains(c) { return digitKeyCodes[Int(c.value - 48)] }
        }
        if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n) { return functionKeys[n - 1] }
        return nil
    }

    /// Top-row digit key codes, indexed by digit (0–9). Not sequential in Carbon.
    static let digitKeyCodes = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
}
