import AppKit
import ApplicationServices
import EuclidCore

/// Writes to the pasteboard and simulates ⌘V into the frontmost app.
/// Simulating keystrokes requires Accessibility permission.
@MainActor
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt (only if not yet granted).
    static func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType(PasteboardFilter.euclidMarker)], owner: nil)
        pb.setString(text, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType(PasteboardFilter.euclidMarker))
    }

    /// Posts ⌘V. Our panel is non-activating, so the previous app is still
    /// frontmost; once the panel is hidden the keystroke lands there.
    static func pasteIntoFrontApp() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Briefly suppress the user's own keystrokes so they can't interleave with the paste.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
