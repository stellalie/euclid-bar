import AppKit
import EuclidCore
import KeyboardShortcuts
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: ConfigService!
    private var panel: PanelController!
    private var clipboard: ClipboardService!
    private let history = HistoryService()
    private let updater = Updater()
    private let hotkeys = CommandHotkeys()
    private let expansion = TextExpansion()
    private var licensing: Licensing!
    private var statusItem: NSStatusItem!
    private var autoInstallItem: NSMenuItem!
    private var expansionItem: NSMenuItem!
    private var licenceHeader: NSMenuItem!
    private var licenceItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make() // needed for ⌘C/⌘V/⌘A in the search field

        config = ConfigService()
        licensing = Licensing(file: config.paths.licenceFile)
        do { try ConfigLoader.installDefaultScripts(in: config.paths.binDirectory) } catch {
            perfLog.error("can't install helper scripts: \(error.localizedDescription, privacy: .public)")
        }
        do { try PluginGuide.install(in: config.paths.pluginsDirectory) } catch {
            perfLog.error("can't write the plugin guide: \(error.localizedDescription, privacy: .public)")
        }
        let settings = config.current.config
        clipboard = ClipboardService(databaseURL: config.paths.historyDatabase, imagesDirectory: config.paths.clipImagesDirectory,
                                     limit: settings.clipboardLimit)
        panel = PanelController(clipboard: clipboard, config: config, history: history)
        panel.onCommand = { [weak self] command in self?.run(command) }
        panel.reminder = { [weak self] in
            guard let self else { return nil }
            updateLicence() // the trial's day count moves on while the app runs
            return licensing.takeReminder(receipt: panel.usageReceipt)
        }
        hotkeys.onPress = { [weak self] hotkey in self?.panel.run(hotkey) }
        panel.extraProblem = { [weak self] in self?.hotkeys.problem ?? self?.expansion.problem }
        expansion.onChange = { [weak self] in self?.panel.updateProblem() }
        setUpStatusItem()
        applyConfig()
        config.onChange = { [weak self] in self?.applyConfig() }
        config.startWatching()
        clipboard.start()

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
        hotkeys.apply(settings.commandHotkeys)
        expansion.configure(enabled: settings.expansionEnabled, snippets: settings.snippets)
        expansionItem.state = settings.expansionEnabled ? .on : .off
        clipboard.ignoredBundleIDs = settings.ignoredApps
        history.configure(enabled: settings.historyEnabled, browsers: settings.historyBrowsers, limit: settings.historyLimit)
        updater.apply(settings.updates)
        autoInstallItem.state = settings.updates.autoInstall ? .on : .off
        panel.configDidChange()
        updateLicence()
    }

    /// Menu, panel commands and footer for the current licence status.
    private func updateLicence() {
        let settings = config.current.config
        panel.commands = AppCommand.updates(settings.updates, version: Updater.version, enabled: updater.isEnabled)
            + (licensing.isEnabled ? AppCommand.licence(summary: licensing.summary, licensed: licensing.isLicensed) : [])
            + [.expansion(enabled: settings.expansionEnabled), .importLauncher, .connectAgents] + AppCommand.usage(receipt: panel.usageReceipt)
        panel.licenceNote = licensing.status == .unregistered ? "Unregistered" : ""
        licenceHeader.isHidden = !licensing.isEnabled
        licenceHeader.title = "Licence · \(licensing.summary)"
        for item in licenceItems { item.isHidden = !licensing.isEnabled || licensing.isLicensed }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), url.host == "toggle" else { return }
        panel.toggle()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = BrainMark.menuBarImage()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Open euclid-bar", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit Config…", action: #selector(editConfig), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Import from Raycast or Alfred…", action: #selector(importLauncher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Connect Claude Code or Codex (MCP)…", action: #selector(connectAgents), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clear Clipboard History…", action: #selector(clearHistory), keyEquivalent: "").target = self
        expansionItem = menu.addItem(withTitle: "Expand Snippet Keywords", action: #selector(toggleExpansion), keyEquivalent: "")
        expansionItem.target = self
        expansionItem.toolTip = "Type a snippet's keyword in any app: [expansion] enabled in config.toml"

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: updater.isEnabled ? "Updates · \(Updater.version)" : "Updates · local build"))
        let check = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = updater.isEnabled
        autoInstallItem = menu.addItem(withTitle: "Install Updates Automatically", action: #selector(toggleAutoInstall), keyEquivalent: "")
        autoInstallItem.target = self
        autoInstallItem.toolTip = "[updates] auto_install in config.toml"

        let licenceSeparator = NSMenuItem.separator()
        licenceSeparator.isHidden = !licensing.isEnabled
        menu.addItem(licenceSeparator)
        licenceHeader = .sectionHeader(title: "Licence")
        menu.addItem(licenceHeader)
        licenceItems = [
            menu.addItem(withTitle: "Buy Licence…", action: #selector(buyLicence), keyEquivalent: ""),
            menu.addItem(withTitle: "Enter Licence Key…", action: #selector(enterLicence), keyEquivalent: ""),
        ]
        for item in licenceItems { item.target = self }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Send Feedback…", action: #selector(sendFeedback), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit euclid-bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openPanel() { panel.show() }

    @objc private func buyLicence() { licensing.openBuyPage() }

    @objc private func enterLicence() {
        if licensing.promptForKey() { updateLicence() }
    }

    @objc private func checkForUpdates() {
        NSApp.activate() // menu-bar app: bring Sparkle's window to the front
        updater.checkForUpdates()
    }

    /// Opens the website's feedback form with the app and macOS versions filled in.
    @objc private func sendFeedback() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var url = URLComponents(string: "https://euclid.lgtmworks.com/feedback/")!
        url.queryItems = [
            URLQueryItem(name: "v", value: Updater.version),
            URLQueryItem(name: "os", value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
        ]
        if let u = url.url { NSWorkspace.shared.open(u) }
    }

    /// Flips `[updates] auto_install` in config.toml; the reload applies it everywhere.
    @objc private func toggleAutoInstall() {
        let updates = config.current.config.updates
        let on = !updates.autoInstall
        // Installing needs checking, so turning it on turns checks on too.
        let problem = (on && !updates.check ? config.set("check", to: true, in: "updates") : nil)
            ?? config.set("auto_install", to: on, in: "updates")
        guard let problem else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't change automatic updates"
        alert.informativeText = problem
        NSApp.activate()
        alert.runModal()
    }

    /// Flips `[expansion] enabled`. Turning it on asks macOS for Accessibility if needed.
    @objc private func toggleExpansion() {
        let on = !config.current.config.expansionEnabled
        guard let problem = config.set("enabled", to: on, in: "expansion") else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't change text expansion"
        alert.informativeText = problem
        NSApp.activate()
        alert.runModal()
    }

    private func run(_ command: AppCommand) {
        switch command.kind {
        case .checkForUpdates:
            guard updater.isEnabled else { NSSound.beep(); return }
            panel.hide()
            checkForUpdates()
        case .toggleAutoInstall:
            toggleAutoInstall()
        case .toggleExpansion:
            toggleExpansion()
        case .buyLicence:
            panel.hide()
            buyLicence()
        case .enterLicence:
            panel.hide()
            enterLicence()
        case .importLauncher:
            panel.hide()
            importLauncher()
        case .connectAgents:
            panel.hide()
            connectAgents()
        case .showUsage:
            panel.hide()
            let alert = NSAlert()
            alert.messageText = "Your last 30 days in Euclid"
            alert.informativeText = (panel.usageReceipt ?? "Nothing yet.")
                .replacingOccurrences(of: " · ", with: "\n") + "\n\nCounted on your Mac only; never what you typed."
            NSApp.activate()
            alert.runModal()
        }
    }

    /// Explain the MCP server and copy the command that connects Claude Code to it.
    @objc private func connectAgents() {
        let alert = NSAlert()
        alert.messageText = "Connect your coding agents"
        let shared = AgentTools.Source.allCases.filter(config.current.config.agentShare.contains).map(\.rawValue)
        alert.informativeText = """
            Euclid can answer your agents over MCP: they search your \(shared.isEmpty ? "(nothing shared)" : shared.joined(separator: ", ")) \
            on this Mac. Choose what with [agents] share in config.toml.

            Claude Code: paste the copied command in a terminal.
            Codex: add to ~/.codex/config.toml:
            [mcp_servers.euclid]
            command = "\(Bundle.main.executablePath ?? "euclid-bar")"
            args = ["--mcp"]
            """
        alert.addButton(withTitle: "Copy Claude Code Command")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { Paster.copy(AgentServer.claudeSetupCommand) }
    }

    /// Pick Raycast/Alfred exports, append what they hold to config.toml, say what happened.
    @objc private func importLauncher() {
        let open = NSOpenPanel()
        open.message = "Choose Raycast snippet or quicklink exports (.json) or Alfred snippets (.alfredsnippets)"
        open.allowsMultipleSelection = true
        open.allowedContentTypes = [.json] + [UTType(filenameExtension: "alfredsnippets")].compactMap { $0 }
        NSApp.activate()
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }

        let settings = config.current.config
        let existing = Set(settings.actions.map(\.name) + settings.snippets.map(\.name))
        let (result, source) = LauncherImporter.read(open.urls, existing: existing)
        let alert = NSAlert()
        if result.isEmpty {
            alert.messageText = "Nothing to import"
        } else if let problem = config.append(LauncherImport.toml(result, source: source)) {
            alert.messageText = "Couldn't import"
            alert.informativeText = problem
            alert.runModal()
            return
        } else {
            alert.messageText = "Imported \(result.snippets.count) snippets and \(result.quicklinks.count) quicklinks"
        }
        let skipped = result.skipped.prefix(8).joined(separator: "\n")
        let more = result.skipped.count > 8 ? "\n…and \(result.skipped.count - 8) more" : ""
        alert.informativeText = result.isEmpty || !skipped.isEmpty
            ? (skipped.isEmpty ? "No snippets or quicklinks found." : "Skipped:\n\(skipped)\(more)")
            : "They're at the end of config.toml. Quicklinks are actions: type a name, or ⌘K."
        alert.runModal()
    }

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
