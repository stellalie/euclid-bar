import AppKit
import EuclidCore
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: ConfigService!
    private var panel: PanelController!
    private var clipboard: ClipboardService!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make() // needed for ⌘C/⌘V/⌘A in the search field

        config = ConfigService()
        do { try ConfigLoader.installDefaultScripts(in: config.paths.binDirectory) } catch {
            perfLog.error("can't install helper scripts: \(error.localizedDescription, privacy: .public)")
        }
        let settings = config.current.config
        clipboard = ClipboardService(databaseURL: config.paths.historyDatabase, limit: settings.clipboardLimit)
        panel = PanelController(clipboard: clipboard, config: config)
        applyConfig()
        config.onChange = { [weak self] in self?.applyConfig() }
        config.startWatching()
        clipboard.start()
        setUpStatusItem()

        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            self?.panel.toggle()
        }

        // Dev hook: `open euclid://toggle` shows the panel without the hotkey.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    /// Apply everything that can change live. (clipboard.limit applies on next launch.)
    private func applyConfig() {
        let settings = config.current.config
        if let hotkey = settings.hotkey { HotkeyBinding.apply(hotkey) }
        clipboard.ignoredBundleIDs = settings.ignoredApps
        panel.configDidChange()
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), url.host == "toggle" else { return }
        panel.toggle()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "euclid-bar")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open euclid-bar", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit Config…", action: #selector(editConfig), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Clear Clipboard History…", action: #selector(clearHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit euclid-bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openPanel() { panel.show() }

    /// Opens config.toml in the default text editor (`open -t`).
    @objc private func editConfig() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", config.paths.configFile.path]
        try? p.run()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all \(clipboard.history.count) clipboard entries?"
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Clear").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { clipboard.clearAll() }
    }
}
