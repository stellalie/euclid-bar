import AppKit
import Carbon.HIToolbox
import EuclidCore

/// Registers `[hotkeys]` (and `hotkey` on actions and snippets) as system-wide hotkeys.
/// Straight Carbon rather than KeyboardShortcuts: config.toml is the only source of truth,
/// so there's nothing to keep in UserDefaults. KeyboardShortcuts' own handler ignores our
/// signature, and ours ignores its, so the panel hotkey keeps working alongside.
@MainActor
final class CommandHotkeys {
    /// A registered hotkey was pressed.
    var onPress: ((CommandHotkey) -> Void)?
    /// Hotkeys macOS refused (another app already has them), for the footer.
    private(set) var problem: String?

    private nonisolated static let signature: OSType = 0x4555_4344 // "EUCD"
    private var applied: [CommandHotkey] = []
    /// By hotkey ID, which is the hotkey's index in `applied`.
    private var registered: [UInt32: (ref: EventHotKeyRef, hotkey: CommandHotkey)] = [:]
    private var handler: EventHandlerRef?

    func apply(_ hotkeys: [CommandHotkey]) {
        guard hotkeys != applied else { return }
        applied = hotkeys
        for r in registered.values { UnregisterEventHotKey(r.ref) }
        registered = [:]
        if !hotkeys.isEmpty { installHandler() }
        var refused: [String] = []
        for (i, h) in hotkeys.enumerated() {
            guard let code = HotkeyBinding.keyCode(h.hotkey.key) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(i))
            let status = RegisterEventHotKey(UInt32(code), Self.carbonModifiers(h.hotkey), id,
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { registered[id.id] = (ref, h) } else { refused.append(h.hotkey.symbols) }
        }
        problem = refused.isEmpty ? nil : "⚠︎ hotkey \(refused.joined(separator: ", ")) is taken (by another app, or the panel)"
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == CommandHotkeys.signature, let context else {
                return OSStatus(eventNotHandledErr)
            }
            let me = Unmanaged<CommandHotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.pressed(id.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func pressed(_ id: UInt32) {
        if let h = registered[id]?.hotkey { onPress?(h) }
    }

    private static func carbonModifiers(_ spec: HotkeySpec) -> UInt32 {
        var m = 0
        if spec.modifiers.contains(.command) { m |= cmdKey }
        if spec.modifiers.contains(.option) { m |= optionKey }
        if spec.modifiers.contains(.control) { m |= controlKey }
        if spec.modifiers.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }
}
