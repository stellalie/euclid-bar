import AppKit
import ApplicationServices
import EuclidCore

/// Writes to the pasteboard and simulates ⌘V into the frontmost app.
/// Simulating keystrokes requires Accessibility permission.
@MainActor
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    /// Stamped on the keystrokes we post (`eventSourceUserData`), so text expansion skips them.
    static let syntheticMarker: Int64 = 0x4555_434C

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

    /// Put a clip back on the pasteboard the way it was copied: text, an image, or files.
    static func copy(_ clip: Clip, imageURL: URL) {
        switch clip.kind {
        case .text:
            copy(clip.content)
        case .image:
            guard let png = try? Data(contentsOf: imageURL) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.declareTypes([.png, .tiff, NSPasteboard.PasteboardType(PasteboardFilter.euclidMarker)], owner: nil)
            pb.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            pb.setString("", forType: NSPasteboard.PasteboardType(PasteboardFilter.euclidMarker))
        case .files:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(clip.paths.map { URL(fileURLWithPath: $0) as NSURL })
            pb.addTypes([NSPasteboard.PasteboardType(PasteboardFilter.euclidMarker)], owner: nil)
            pb.setString("", forType: NSPasteboard.PasteboardType(PasteboardFilter.euclidMarker))
        }
    }

    /// Posts ⌘V. Our panel is non-activating, so the previous app is still
    /// frontmost; once the panel is hidden the keystroke lands there.
    static func pasteIntoFrontApp() {
        press(9, flags: .maskCommand) // kVK_ANSI_V
    }

    /// Posts ⌫ `count` times into the front app (text expansion removing the keyword).
    static func deleteBackward(_ count: Int) {
        for _ in 0..<count { press(51, flags: []) } // kVK_Delete
    }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Briefly suppress the user's own keystrokes so they can't interleave with ours.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags // also clears a still-held ⇧ from the keystroke that triggered us
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            e.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Everything on the general pasteboard, to put back after borrowing it.
    static func saveContents() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    /// Put saved contents back, marked as ours so clipboard history doesn't record them again.
    static func restore(_ items: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !items.isEmpty else { return }
        items[0].setString("", forType: NSPasteboard.PasteboardType(PasteboardFilter.euclidMarker))
        pb.writeObjects(items)
    }
}
