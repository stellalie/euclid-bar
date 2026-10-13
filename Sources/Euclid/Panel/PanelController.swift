import AppKit
import EuclidCore
import os

let perfLog = Logger(subsystem: "dev.euclid", category: "perf")
let signposter = OSSignposter(subsystem: "dev.euclid", category: "perf")

/// Owns the panel's lifecycle. The panel is built once at launch and only
/// shown/hidden afterwards — never created on the hotkey path.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: LauncherPanel
    private let content: LauncherViewController

    init(items: [SearchItem]) {
        content = LauncherViewController(items: items)
        panel = LauncherPanel(size: LauncherViewController.size)
        super.init()
        panel.contentViewController = content
        panel.setContentSize(LauncherViewController.size)
        panel.delegate = self
        content.onClose = { [weak self] in self?.hide() }
    }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("show")
        position()
        content.prepareForShow()
        panel.makeKeyAndOrderFront(nil)
        panel.displayIfNeeded()
        // End on the next run-loop turn, after the frame has been committed.
        DispatchQueue.main.async {
            signposter.endInterval("show", state)
            perfLog.notice("show: \(String(describing: ContinuousClock.now - start), privacy: .public)")
        }
    }

    func hide() { panel.orderOut(nil) }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// Center horizontally on the screen under the mouse, upper third vertically.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.66 - size.height / 2
        ))
    }
}
