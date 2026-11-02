import AppKit
import EuclidCore
import KeyboardShortcuts

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
    private var crashReportsItem: NSMenuItem!
    private var usagePingItem: NSMenuItem!
    private var expansionItem: NSMenuItem!
    private var openAtLoginItem: NSMenuItem!
    private var licenceHeader: NSMenuItem!
    private var licenceItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make() // needed for ⌘C/⌘V/⌘A in the search field

        config = ConfigService()
        licensing = Licensing(file: config.paths.licenceFile)
        do { try ConfigLoader.installDefaultScripts(in: config.paths.binDirectory) } catch {
            perfLog.error("can't install helper scripts: \(error.localizedDescription, privacy: .public)")
            CrashReporter.error("setup", "can't install helper scripts: \(error.localizedDescription)")
        }
        do { try PluginGuide.install(in: config.paths.pluginsDirectory) } catch {
            perfLog.error("can't write the plugin guide: \(error.localizedDescription, privacy: .public)")
            CrashReporter.error("setup", "can't write the plugin guide: \(error.localizedDescription)")
        }
        let settings = config.current.config
        clipboard = ClipboardService(databaseURL: config.paths.historyDatabase, imagesDirectory: config.paths.clipImagesDirectory,
                                     limit: settings.clipboardLimit)
        panel = PanelController(clipboard: clipboard, config: config, history: history)
        panel.onCommand = { [weak self] command in self?.run(command) }
        panel.reminder = { [weak self] in
            guard let self else { return nil }
            updateLicence() // the trial's day count moves on while the app runs
            return licensing.takeReminder()
        }
        hotkeys.onPress = { [weak self] hotkey in self?.panel.run(hotkey) }
        panel.extraProblem = { [weak self] in
            guard let self else { return nil }
            return hotkeys.problem ?? Permissions.footer(missingPermissions())
        }
        expansion.onChange = { [weak self] in self?.updateLicence(); self?.panel.updateProblem() }
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
        firstLaunch()
    }

    /// Once per Mac: ask about reports, then open the panel with a welcome, so a menu-bar-only app
    /// doesn't start silently and people learn the hotkey.
    private func firstLaunch() {
        let asked = "askedAboutReports"
        guard !UserDefaults.standard.bool(forKey: asked) else { return }
        UserDefaults.standard.set(true, forKey: asked)
        askAboutReports()
        let hotkey = config.current.config.hotkey?.symbols ?? "⌥Space"
        panel.welcome = "Welcome! Press \(hotkey) in any app to open Euclid. Settings: menu bar icon → Edit Config…"
        NSApp.activate()
        panel.show()
    }

    /// Offer crash reports and the usage ping, both unticked: nothing is sent unless you tick them.
    private func askAboutReports() {
        let settings = config.current.config
        guard !settings.crashReports || !settings.usagePing else { return }

        let crash = NSButton(checkboxWithTitle: "Send crash reports: the crashed code's stack and versions", target: nil, action: nil)
        let ping = NSButton(checkboxWithTitle: "Send a daily usage ping: a random install ID and versions", target: nil, action: nil)
        crash.state = settings.crashReports ? .on : .off
        ping.state = settings.usagePing ? .on : .off
        let boxes = NSStackView(views: [crash, ping])
        boxes.orientation = .vertical
        boxes.alignment = .leading
        boxes.setFrameSize(boxes.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Help make Euclid better?"
        alert.informativeText = "Both are anonymous: never your searches, clipboard, files or config. "
            + "Change them any time in the menu bar icon, or under [privacy] in config.toml."
        alert.accessoryView = boxes
        alert.addButton(withTitle: "Continue")
        NSApp.activate()
        alert.runModal()
        for (key, box, current) in [("crash_reports", crash, settings.crashReports), ("usage_ping", ping, settings.usagePing)] {
            let on = box.state == .on
            if on != current, let problem = config.set(key, to: on, in: "privacy") {
                perfLog.error("can't save [privacy] \(key, privacy: .public): \(problem, privacy: .public)")
            }
        }
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
        CrashReporter.shared.apply(enabled: settings.crashReports, channel: settings.updates.channel)
        crashReportsItem.state = settings.crashReports ? .on : .off
        UsagePinger.shared.apply(enabled: settings.usagePing, channel: settings.updates.channel)
        usagePingItem.state = settings.usagePing ? .on : .off
        autoInstallItem.state = settings.updates.autoInstall ? .on : .off
        if let problem = LoginItem.apply(settings.openAtLogin) { CrashReporter.error("login-item", problem) }
        panel.configDidChange()
        updateLicence()
    }

    /// Menu, panel commands and footer for the current licence status.
    private func updateLicence() {
        let settings = config.current.config
        panel.commands = AppCommand.updates(settings.updates, version: Updater.version, enabled: updater.isEnabled)
            + (licensing.isEnabled ? AppCommand.licence(summary: licensing.summary, licensed: licensing.isLicensed) : [])
            + [.permissions(missingPermissions()), .expansion(enabled: settings.expansionEnabled)]
            + (LoginItem.isAvailable ? [.openAtLogin(enabled: LoginItem.isEnabled)] : [])
            + [.crashReports(enabled: settings.crashReports),
               .usagePing(enabled: settings.usagePing), .connectAgents]
        openAtLoginItem.state = LoginItem.isEnabled ? .on : .off
        openAtLoginItem.isEnabled = LoginItem.isAvailable
        panel.licenceNote = licensing.status == .unregistered ? "Unregistered" : ""
        licenceHeader.isHidden = !licensing.isEnabled
        licenceHeader.title = "Licence · \(licensing.summary)"
        for item in licenceItems { item.isHidden = !licensing.isEnabled || licensing.isLicensed }
    }

    private func missingPermissions() -> [Permissions.Need] {
        Permissions.missing(.init(accessibility: Paster.isTrusted, expansionEnabled: config.current.config.expansionEnabled,
                                  safariBlocked: history.safariBlocked, safariRequested: history.safariRequested,
                                  blockedBrowsers: history.blockedBrowsers))
    }

    /// Open System Settings at the first missing permission (and add Euclid to the Accessibility list).
    private func openPermissions() {
        guard let need = missingPermissions().first else { return }
        if need.kind == .accessibility { Paster.requestPermission() }
        NSWorkspace.shared.open(need.pane)
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
        menu.addItem(withTitle: "Open Euclid", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit Config…", action: #selector(editConfig), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Connect Claude Code or Codex (MCP)…", action: #selector(connectAgents), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clear Clipboard History…", action: #selector(clearHistory), keyEquivalent: "").target = self
        expansionItem = menu.addItem(withTitle: "Expand Snippet Keywords", action: #selector(toggleExpansion), keyEquivalent: "")
        expansionItem.target = self
        expansionItem.toolTip = "Type a snippet's keyword in any app: [expansion] enabled in config.toml"
        openAtLoginItem = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        openAtLoginItem.target = self
        openAtLoginItem.toolTip = "Start Euclid when you log in: [startup] open_at_login in config.toml"

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: updater.isEnabled ? "Updates · \(Updater.version)" : "Updates · local build"))
        let check = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = updater.isEnabled
        autoInstallItem = menu.addItem(withTitle: "Install Updates Automatically", action: #selector(toggleAutoInstall), keyEquivalent: "")
        autoInstallItem.target = self
        autoInstallItem.toolTip = "[updates] auto_install in config.toml"
        crashReportsItem = menu.addItem(withTitle: "Send Crash Reports", action: #selector(toggleCrashReports), keyEquivalent: "")
        crashReportsItem.target = self
        crashReportsItem.toolTip = "Stack and versions only, never your data: [privacy] crash_reports in config.toml"
        usagePingItem = menu.addItem(withTitle: "Send Anonymous Usage Ping", action: #selector(toggleUsagePing), keyEquivalent: "")
        usagePingItem.target = self
        usagePingItem.toolTip = "Once a day: a random install ID and versions, so installs can be counted: [privacy] usage_ping in config.toml"

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
        menu.addItem(withTitle: "Quit Euclid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        Self.addMenuIcons(to: menu)
        statusItem.menu = menu
    }

    /// macOS 26 shows icons beside menu items, but only guesses them for standard actions,
    /// so custom items like "Send Feedback…" were left blank. Give every action item its own
    /// symbol; checkmark toggles keep none, like the system menus. Older macOS shows no icons.
    private static func addMenuIcons(to menu: NSMenu) {
        guard #available(macOS 26, *) else { return }
        let symbols: [String: String] = [
            "Open Euclid": "magnifyingglass",
            "Edit Config…": "gearshape",
            "Connect Claude Code or Codex (MCP)…": "link",
            "Clear Clipboard History…": "trash",
            "Check for Updates…": "arrow.down.circle",
            "Buy Licence…": "cart",
            "Enter Licence Key…": "key",
            "Send Feedback…": "exclamationmark.bubble",
            "Quit Euclid": "power",
        ]
        for item in menu.items {
            guard let name = symbols[item.title] else { continue }
            item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
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
        var url = URLComponents(string: "https://lgtm.ninja/euclid/feedback/")!
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

    /// Flips `[privacy] crash_reports`.
    @objc private func toggleCrashReports() {
        guard let problem = config.set("crash_reports", to: !config.current.config.crashReports, in: "privacy") else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't change crash reports"
        alert.informativeText = problem
        NSApp.activate()
        alert.runModal()
    }

    /// Flips `[privacy] usage_ping`.
    @objc private func toggleUsagePing() {
        guard let problem = config.set("usage_ping", to: !config.current.config.usagePing, in: "privacy") else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't change the usage ping"
        alert.informativeText = problem
        NSApp.activate()
        alert.runModal()
    }

    /// Flips what macOS has now (it may differ from config.toml if switched in System Settings), and saves it to
    /// `[startup] open_at_login`.
    @objc private func toggleOpenAtLogin() {
        let on = !LoginItem.isEnabled
        let problem = LoginItem.apply(on, force: true) ?? config.set("open_at_login", to: on, in: "startup")
        updateLicence()
        guard let problem else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't change Open at Login"
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
        case .toggleOpenAtLogin:
            toggleOpenAtLogin()
        case .toggleCrashReports:
            toggleCrashReports()
        case .toggleUsagePing:
            toggleUsagePing()
        case .buyLicence:
            panel.hide()
            buyLicence()
        case .enterLicence:
            panel.hide()
            enterLicence()
        case .connectAgents:
            panel.hide()
            connectAgents()
        case .permissions:
            guard !missingPermissions().isEmpty else { NSSound.beep(); return }
            panel.hide()
            openPermissions()
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

    /// Opens config.toml with `editor` (an app or a command), or the default text editor.
    /// Runs like an action (login shell), so `subl`/`code` on your PATH work.
    @objc private func editConfig() {
        let settings = config.current.config
        let editor = settings.editor
        let command = EditorCommand.command(for: editor) { EditorCommand.isApp($0, folders: settings.appFolders) }
        let file = config.paths.configFile.path
        let env = ProcessInfo.processInfo.environment.merging(settings.environment) { $1 }
        CommandRunner.runInBackground(shell: settings.shellPath, command: command, query: file,
                                      pathPrefix: config.paths.binDirectory.path, baseEnvironment: env) { result in
            guard case .failure(let failure) = result, let editor else { return }
            DispatchQueue.main.async {
                // Still get the file open, then say why the editor didn't work.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-t", file]
                try? p.run()
                let alert = NSAlert()
                alert.messageText = "Couldn't open config.toml with “\(editor)”"
                alert.informativeText = "\(failure.description)\n\nSet editor in config.toml to an app name (\"Sublime Text\") or a command on your PATH (\"subl\", \"code\")."
                NSApp.activate()
                alert.runModal()
            }
        }
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
