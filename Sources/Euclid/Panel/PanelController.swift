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
    private let clipboard: ClipboardService
    private let config: ConfigService

    init(clipboard: ClipboardService, config: ConfigService) {
        self.clipboard = clipboard
        self.config = config
        content = LauncherViewController(items: { [unowned clipboard] in clipboard.history.items })
        panel = LauncherPanel(size: LauncherViewController.size)
        super.init()
        panel.contentViewController = content
        panel.setContentSize(LauncherViewController.size)
        panel.delegate = self
        content.onClose = { [weak self] in self?.hide() }
        content.onPaste = { [weak self] id in self?.paste(id: id) }
        content.onCopy = { [weak self] id in self?.copy(id: id) }
        content.onDelete = { [weak clipboard] id in clipboard?.delete(id: id) }
        content.onRunAction = { [weak self] action, query in self?.run(action, query: query) }
        clipboard.onChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.content.refreshAfterExternalChange()
        }
        configDidChange()
    }

    /// Push the current config into the panel (called on launch and every reload).
    func configDidChange() {
        content.actions = config.current.config.actions
        content.problem = config.problemSummary
    }

    /// Run an action on the query. Hides first so the result (a browser tab,
    /// a terminal…) gets focus. Failures show in the footer next time.
    private func run(_ action: Action, query: String) {
        hide()
        let name = action.name
        perfLog.notice("run action '\(name, privacy: .public)'")
        let shell = config.current.config.shellPath
        let completion: @Sendable (Result<Void, CommandRunner.Failure>) -> Void = { [weak self] result in
            guard case .failure(let failure) = result else { return }
            DispatchQueue.main.async {
                perfLog.error("action '\(name, privacy: .public)' failed: \(failure.description, privacy: .public)")
                self?.content.notice = "⚠︎ “\(name)” failed (\(failure.description))"
            }
        }
        CommandRunner.runInBackground(shell: shell, command: action.run, query: query,
                                      pathPrefix: config.paths.binDirectory.path, completion: completion)
    }

    /// Enter: put the entry on the pasteboard, hide, and ⌘V into the previous app.
    /// Without Accessibility permission we fall back to copy-only and ask once.
    private func paste(id: Int) {
        guard let clip = clipboard.history.clip(id: id) else { return }
        Paster.copy(clip.content)
        clipboard.markUsed(id: id)
        hide()
        guard Paster.isTrusted else {
            Paster.requestPermission()
            return
        }
        // Give the previous app's window a beat to become key again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Paster.pasteIntoFrontApp() }
    }

    private func copy(id: Int) {
        guard let clip = clipboard.history.clip(id: id) else { return }
        Paster.copy(clip.content)
        clipboard.markUsed(id: id)
        hide()
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

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        content.didHide()
    }

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
