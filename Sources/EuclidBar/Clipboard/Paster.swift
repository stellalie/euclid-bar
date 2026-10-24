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
