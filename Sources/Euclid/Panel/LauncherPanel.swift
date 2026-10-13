import AppKit

/// Borderless, non-activating floating panel.
/// Non-activating = the previous app stays frontmost, so Esc "returns focus"
/// for free and step 2's paste goes straight into that app.
final class LauncherPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none // instant show/hide
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
