import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    @MainActor static let togglePanel = Self("togglePanel", default: .init(.space, modifiers: [.option]))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make() // needed for ⌘C/⌘V/⌘A in the search field
        panel = PanelController(items: SampleData.make())
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

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), url.host == "toggle" else { return }
        panel.toggle()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "function", accessibilityDescription: "Euclid")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Euclid", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Euclid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openPanel() { panel.show() }
}
