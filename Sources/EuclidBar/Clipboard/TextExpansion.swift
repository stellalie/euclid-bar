import AppKit
import EuclidCore

/// `[expansion] enabled`: type a snippet's keyword in any app and it turns into the snippet.
/// Watches keystrokes with a global monitor (passive: it never delays or swallows a key),
/// then deletes the keyword and types the text (or, for long or multi-line text, pastes it and
/// puts your clipboard back afterwards).
/// Needs Accessibility access, the same permission pasting from the panel uses.
@MainActor
final class TextExpansion {
    /// Changed when the footer message should change (waiting for access, or got it).
    var onChange: (() -> Void)?
    /// For the footer while expansion is on but macOS hasn't allowed it yet.
    var problem: String? {
        enabled && !Paster.isTrusted
            ? "⚠︎ Text expansion needs Accessibility: System Settings › Privacy & Security › Accessibility"
            : nil
    }

    private var enabled = false
    private var expander = TextExpander(snippets: [])
    private var monitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var trustTimer: Timer?
    private var askedForAccess = false

    func configure(enabled: Bool, snippets: [Snippet]) {
        expander = TextExpander(snippets: snippets)
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled { start() } else { stop() }
        onChange?()
    }

    private func start() {
        guard Paster.isTrusted else {
            // A global key monitor added before access is granted never gets keys: wait for it.
            if !askedForAccess {
                askedForAccess = true
                Paster.requestPermission()
            }
            trustTimer?.invalidate()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, Paster.isTrusted else { return }
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    self.start()
                    self.onChange?()
                }
            }
            return
        }
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(m) }
        // A click can move the cursor anywhere: what was typed before no longer leads up to it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.expander.reset() }
        }) { monitors.append(m) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.expander.reset() }
        }
    }

    private func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        expander.reset()
    }

    /// Keys that move the cursor or leave the field: ↩ ⇥ ⎋, arrows, Home/End, Page Up/Down, ⌦.
    private static let cursorKeys: Set<UInt16> = [36, 76, 48, 53, 123, 124, 125, 126, 115, 119, 116, 121, 117]

    private func handle(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Paster.syntheticMarker { return } // our own ⌫ and ⌘V
        if event.keyCode == 51 { expander.deleteBackward(); return } // ⌫
        let shortcut = !event.modifierFlags.intersection([.command, .control]).isEmpty
        guard !shortcut, !Self.cursorKeys.contains(event.keyCode),
              let chars = event.characters, !chars.isEmpty,
              !chars.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) // function keys
        else { expander.reset(); return }
        if let match = expander.typed(chars) { expand(match) }
    }

    /// Longest text typed out as keystrokes; anything longer, or with a newline, is pasted.
    static let maxTyped = 200

    private func expand(_ match: TextExpander.Match) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        let text = match.snippet.expanded(clipboard: { clipboard }) + match.suffix
        Paster.deleteBackward(match.deleteCount)
        // Short one-liners are typed: no clipboard to borrow, so nothing can paste the wrong thing.
        if text.count <= Self.maxTyped, !text.contains(where: \.isNewline) {
            Paster.type(text)
            return
        }
        let saved = Paster.saveContents()
        Paster.copy(text)
        let ours = NSPasteboard.general.changeCount
        Paster.pasteIntoFrontApp()
        // The app reads the pasteboard when it gets to our ⌘V. Slow apps (Electron, a busy main
        // thread) can take a while, and restoring first would paste the old clipboard: wait 1 s.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // Only if nothing else was copied in the meantime.
            if NSPasteboard.general.changeCount == ours { Paster.restore(saved) }
        }
    }
}
