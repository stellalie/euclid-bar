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
    private let history: HistoryService
    private let apps: BackgroundIndex<AppEntry>
    private let projects: BackgroundIndex<ProjectEntry>
    private let files: FileSearchService
    private let contentSearch: ContentService
    private let plugins: PluginService
    private let ranking: RankingService
    /// euclid-bar's own commands, for search. The app delegate runs them.
    var commands: [AppCommand] {
        get { content.commands }
        set { content.commands = newValue }
    }
    var onCommand: ((AppCommand) -> Void)?
    /// Asked each time the panel opens: a one-off footer message (the licence reminder).
    var reminder: (() -> String?)?
    /// Shown in the footer the next time the panel opens, once (the first-launch welcome).
    var welcome: String?
    /// "412 opens on 21 days · 120 apps, 38 actions" for the last 30 days, or nil before any use.
    /// Shown after the search speed while unregistered.
    var licenceNote: String {
        get { content.licenceNote }
        set { content.licenceNote = newValue }
    }
    /// Footer problems from outside the panel (hotkeys macOS refused, text expansion waiting for access).
    var extraProblem: () -> String? = { nil }
    /// Where the panel's top edge sits while it's open: it grows and shrinks downwards from here.
    private var anchor: NSPoint?
    /// The last text a hook put on the clipboard, so clipboard hooks don't react to their own copy.
    private var hookCopy: String?
    private var appObserver: NSObjectProtocol?
    /// The app you're in, for `open` hooks (`frontmostApplication` goes stale in an accessory app).
    private var frontApp = (name: "", id: "")
    /// The item `run` the panel is waiting on (up to 1 s) before it hides.
    private var waitingRun: UUID?

    init(clipboard: ClipboardService, config: ConfigService, history: HistoryService) {
        self.clipboard = clipboard
        self.config = config
        self.history = history
        apps = BackgroundIndex(name: "apps", maxAge: .seconds(60)) { $0.searchItem(id: $1) }
        projects = BackgroundIndex(name: "projects", maxAge: .seconds(300)) { $0.searchItem(id: $1) }
        files = FileSearchService()
        contentSearch = ContentService(databaseURL: config.paths.contentDatabase)
        ranking = RankingService(databaseURL: config.paths.rankingDatabase)
        plugins = PluginService(binDirectory: config.paths.binDirectory.path)
        content = LauncherViewController(items: { [unowned clipboard] in clipboard.history.items })
        panel = LauncherPanel(size: LauncherViewController.size)
        super.init()
        panel.contentViewController = content
        panel.setContentSize(LauncherViewController.size)
        panel.delegate = self
        // Footer tips retire once you've used what they show.
        content.onFeatureUsed = { feature in
            var used = UserDefaults.standard.stringArray(forKey: PanelController.usedFeaturesKey) ?? []
            guard !used.contains(feature) else { return }
            used.append(feature)
            UserDefaults.standard.set(used, forKey: PanelController.usedFeaturesKey)
        }
        content.onClose = { [weak self] in self?.hide() }
        content.onPaste = { [weak self] id in self?.paste(id: id) }
        content.onCopy = { [weak self] id in self?.copy(id: id) }
        content.onDelete = { [weak clipboard] id in clipboard?.delete(id: id) }
        content.clip = { [unowned clipboard] id in clipboard.history.clip(id: id) }
        content.clipImage = { [unowned clipboard] clip in clipboard.image(for: clip) }
        content.onPasteText = { [weak self] text in self?.pasteText(text) }
        content.onOpenNote = { [weak self] path in self?.openNote(path: path) }
        content.onPreferredSizeChange = { [weak self] size in self?.resize(to: size) }
        content.onRunAction = { [weak self] action, query in self?.run(action, query: query) }
        content.onRunTask = { [weak self] task in
            guard let self else { return }
            self.run(Action(name: task.command, run: self.config.current.config.projectTask), query: task.commandLine)
        }
        content.onCommand = { [weak self] command in self?.onCommand?(command) }
        content.historyProvider = { [unowned history] in history.items }
        content.historyURL = { [unowned history] id in history.entry(id: id)?.url }
        content.favicon = { [unowned history] host in history.favicon(host: host) }
        content.contentSearch = { [unowned contentSearch] text in contentSearch.search(text) }
        content.contentBody = { [unowned contentSearch] ref in contentSearch.body(ref: ref) }
        contentSearch.onResults = { [weak self] text, hits in self?.content.setContentResults(hits, for: text) }
        content.pluginProvider = { [unowned plugins] in plugins.items }
        content.pluginEntry = { [unowned plugins] id in plugins.entry(id: id) }
        content.pluginAnswer = { [unowned plugins] text in plugins.answer(text) }
        content.pluginDirectory = { [unowned plugins] id in plugins.plugin(id: id)?.directory }
        content.onPluginItem = { [weak self] entry in self?.activate(entry) }
        content.onBadgeClick = { [weak self] id in self?.clickBadge(pluginID: id) }
        content.onReloadView = { [weak self] command, pluginID, viewID, query in
            // A search gets what you typed as $1 and may print just rows.
            self?.plugins.run(command, pluginID: pluginID, arguments: query.map { [$0] }, rows: query != nil) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let r):
                    self.content.viewReloaded(viewID, with: r.view, query: query)
                case .failure(let failure):
                    self.content.viewReloaded(viewID, with: nil, query: query)
                    if !failure.stillRunning { self.content.notice = "⚠︎ Refresh failed (\(failure.description))" }
                }
            }
        }
        plugins.onAnswers = { [weak self] text, entries, reveal in self?.content.setPluginAnswers(entries, for: text, reveal: reveal) }
        plugins.onChange = { [weak self] in
            guard let self else { return }
            self.content.badges = self.plugins.badges
            self.updateProblem()
            if self.panel.isVisible { self.content.refreshAfterExternalChange() }
        }
        // Mods: hooks and keys.
        let front = NSWorkspace.shared.frontmostApplication
        frontApp = (front?.localizedName ?? "", front?.bundleIdentifier ?? "")
        plugins.onEffects = { [weak self] id, name, effects in self?.apply(effects, from: name, pluginID: id) }
        content.onModKey = { [weak self] pluginID, key, item in
            guard let self else { return }
            let query = self.content.query
            self.hide()
            self.plugins.runKey(key, pluginID: pluginID, item: item, query: query)
        }
        content.onChoose = { [unowned plugins] item in
            guard plugins.hasHooks(for: .choose) else { return }
            plugins.fire(.choose, input: item.value, environment: item.environment)
        }
        clipboard.onText = { [weak self] text, app in
            guard let self, self.plugins.hasHooks(for: .clipboard) else { return }
            if text == self.hookCopy { self.hookCopy = nil; return }
            guard text.utf8.count <= 100_000 else { return } // too big to pass as an argument
            self.plugins.fire(.clipboard, input: text, environment: ["EUCLID_APP": app ?? ""])
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.localizedName ?? "", id = app?.bundleIdentifier ?? ""
            guard id != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frontApp = (name, id)
                guard self.plugins.hasHooks(for: .app) else { return }
                self.plugins.fire(.app, input: name, environment: ["EUCLID_APP_ID": id])
            }
        }
        content.onOpenHistory = { [weak self] id in self?.openHistory(id: id) }
        content.onCopyHistory = { [weak self] id in
            guard let self, let entry = self.history.entry(id: id) else { return }
            Paster.copy(entry.url)
            self.hide()
        }
        content.appsProvider = { [unowned apps] in apps.items }
        content.projectsProvider = { [unowned projects] in projects.items }
        content.project = { [unowned projects] id in projects.entry(id: id) }
        content.ranking = ranking
        content.fileSearch = { [unowned files] text in files.search(text) }
        files.onResults = { [weak self] text, hits in self?.content.setFileResults(hits, for: text) }
        content.onOpenApp = { [weak self] path in self?.openApp(path: path) }
        content.onOpenProject = { [weak self] path in self?.openProject(path: path) }
        content.onOpenFile = { [weak self] path in
            self?.hide()
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        content.onCopyText = { [weak self] text in
            Paster.copy(text)
            self?.hide()
        }
        apps.onChange = { [weak self] in self?.indexDidChange() }
        projects.onChange = { [weak self] in self?.indexDidChange() }
        history.onChange = { [weak self] in
            guard let self else { return }
            self.updateProblem()
            if self.panel.isVisible { self.content.refreshAfterExternalChange() }
        }
        clipboard.onChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.content.refreshAfterExternalChange()
        }
        configDidChange()
    }

    /// Push the current config into the panel (called on launch and every reload).
    func configDidChange() {
        let settings = config.current.config
        content.actions = settings.actions
        content.aliases = settings.aliases
        content.favorites = settings.favorites
        content.snippets = settings.snippets
        content.hotkeys = settings.commandHotkeys
        content.theme = Theme(settings.appearance)
        content.scopePrefixes = settings.scopePrefixes
        content.hasNotes = settings.obsidianVault != nil
        content.hasFiles = settings.filesEnabled
        contentSearch.configure(vault: settings.obsidianVault)
        plugins.configure(settings.plugins, shell: settings.shellPath, environment: settings.environment)
        content.badges = plugins.badges
        content.modKeys = plugins.keys
        files.enabled = settings.filesEnabled
        files.limit = settings.filesLimit
        let folders = settings.appFolders
        if settings.appsEnabled { apps.configure { AppIndex.scan(folders: folders) } } else { apps.configure(nil) }
        let roots = settings.projectRoots, depth = settings.projectDepth
        if roots.isEmpty { projects.configure(nil) } else {
            projects.configure { ProjectScanner.scan(roots: roots, maxDepth: depth) }
        }
        updateProblem()
    }

    private func indexDidChange() {
        if panel.isVisible { content.refreshAfterExternalChange() }
    }

    /// Launch the app, or bring it to the front if it's running.
    private func openApp(path: String) {
        hide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.content.notice = "⚠︎ couldn't open app (\(message))" }
            }
        }
    }

    /// Open a note in Obsidian; if that doesn't work (no Obsidian), in the default app.
    private func openNote(path: String) {
        hide()
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        if let url = c.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Run `[projects] open` with the repo's path as $1.
    private func openProject(path: String) {
        run(Action(name: "Open project", run: config.current.config.projectOpen), query: path)
    }

    func updateProblem() {
        content.problem = config.problemSummary ?? extraProblem() ?? history.problem ?? plugins.problem
    }

    /// A `[hotkeys]` hotkey: open, run or paste what it names, without showing the panel.
    func run(_ hotkey: CommandHotkey) {
        guard let row = content.row(for: hotkey) else {
            NSSound.beep()
            perfLog.error("hotkey \(hotkey.hotkey.symbols, privacy: .public): nothing named '\(hotkey.target, privacy: .public)'")
            content.notice = "⚠︎ hotkey \(hotkey.hotkey.symbols): no app, project, action or snippet named “\(hotkey.target)”"
            return
        }
        content.activate(row, query: "")
    }

    /// Open a history entry in the browser it came from.
    private func openHistory(id: Int) {
        guard let entry = history.entry(id: id), let url = URL(string: entry.url) else { return }
        hide()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", entry.browser, url.absoluteString]
        p.terminationHandler = { proc in
            // Display name isn't always the app name: fall back to the default browser.
            if proc.terminationStatus != 0 { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [url.absoluteString]) }
        }
        try? p.run()
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
        let env = ProcessInfo.processInfo.environment.merging(config.current.config.environment) { $1 }
            .merging(action.environment) { $1 }
        CommandRunner.runInBackground(shell: shell, command: action.run, query: query,
                                      pathPrefix: config.paths.binDirectory.path, directory: action.directory,
                                      baseEnvironment: env, completion: completion)
    }

    /// ↵ on a plugin's item: the first of open, paste, copy, run that it set,
    /// or, on an “Ask” row, its answer (the panel stays open for the reply).
    private func activate(_ entry: PluginService.Entry) {
        let item = entry.item
        if entry.ask != nil {
            plugins.ask(entry, query: content.query)
        } else if let open = item.open {
            hide()
            let expanded = (open as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: expanded)) }
            else if let url = URL(string: open) { NSWorkspace.shared.open(url) }
        } else if let text = item.paste {
            pasteText(text)
        } else if let text = item.copy {
            Paster.copy(text)
            hide()
        } else if let run = item.run {
            runPluginCommand(run, pluginID: entry.pluginID, label: item.title, arguments: entry.arguments)
        } else if let first = item.actions?.first {
            // Nothing of its own to do: ↵ does its first action.
            activate(PluginService.Entry(pluginID: entry.pluginID, pluginName: entry.pluginName, item: first))
        }
    }

    /// What a hook or key script asked for.
    private func apply(_ effects: [PluginEffect], from pluginName: String, pluginID: String) {
        for e in effects {
            if let text = e.copy {
                hookCopy = text
                Paster.copy(text)
            }
            if let text = e.paste {
                hookCopy = text
                pasteText(text)
            }
            if let text = e.show {
                if !panel.isVisible { show() }
                plugins.present(text, pluginName: pluginName, pluginID: pluginID, query: content.query)
            }
            if let open = e.open {
                hide()
                let expanded = (open as NSString).expandingTildeInPath
                if expanded.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: expanded)) }
                else if let url = URL(string: open) { NSWorkspace.shared.open(url) }
            }
            if let query = e.query, panel.isVisible { content.suggestQuery(query) }
            if let notice = e.notice {
                // Shown now if the panel is open, else the next time it opens.
                content.notice = notice.hasPrefix("⚠︎") ? notice : "\(pluginName): \(notice)"
            }
        }
    }

    private func clickBadge(pluginID: String) {
        guard let click = plugins.plugin(id: pluginID)?.badge?.click else { return }
        runPluginCommand(click, pluginID: pluginID, label: plugins.plugin(id: pluginID)?.name ?? pluginID, arguments: nil)
    }

    /// An item's `run` (or a badge's `click`). The panel waits up to 1 s for it, so what it prints
    /// lands in the open panel: a view opens, a notice shows in the footer (↵ again repeats it).
    /// Anything else, or a slower command, closes the panel; its effects still apply when it's done.
    private func runPluginCommand(_ command: String, pluginID: String, label: String, arguments: [String]?) {
        let token = UUID()
        waitingRun = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.waitingRun == token else { return }
            self.waitingRun = nil
            self.hide()
        }
        let name = plugins.plugin(id: pluginID)?.name ?? pluginID
        plugins.run(command, pluginID: pluginID, arguments: arguments) { [weak self] result in
            guard let self else { return }
            let waited = self.waitingRun == token
            if waited { self.waitingRun = nil }
            switch result {
            case .failure(let failure) where failure.stillRunning:
                return
            case .failure(let failure):
                self.content.notice = "⚠︎ “\(label)” failed (\(failure.description))"
            case .success(let r):
                var effects = r.effects
                if let problem = r.problems.first { effects.append(PluginEffect(notice: "⚠︎ \(problem)")) }
                let staysOpen = r.view != nil || effects.contains { $0.show != nil || $0.notice != nil }
                if waited, !staysOpen { self.hide() }
                if !effects.isEmpty { self.apply(effects, from: name, pluginID: pluginID) }
                if let view = r.view {
                    if !self.panel.isVisible { self.show() }
                    self.content.present(view, pluginID: pluginID, pluginName: name)
                } else if self.panel.isVisible {
                    self.content.reloadTopView() // a live view shows what the run changed
                }
            }
        }
    }

    /// Enter: put the entry on the pasteboard, hide, and ⌘V into the previous app.
    /// Without Accessibility permission we fall back to copy-only and ask once.
    private func paste(id: Int) {
        guard let clip = clipboard.history.clip(id: id) else { return }
        Paster.copy(clip, imageURL: clipboard.imageURL(clip))
        clipboard.markUsed(id: id)
        pasteIntoPreviousApp()
    }

    /// A snippet: paste the text without recording it as a clip.
    private func pasteText(_ text: String) {
        Paster.copy(text)
        pasteIntoPreviousApp()
    }

    private func pasteIntoPreviousApp() {
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
        Paster.copy(clip, imageURL: clipboard.imageURL(clip))
        clipboard.markUsed(id: id)
        hide()
    }

    func toggle() { panel.isVisible ? hide() : show() }

    private static let tipOpensKey = "tipOpens"
    private static let usedFeaturesKey = "usedFeatures"

    func show() {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("show")
        anchor = topCenter()
        history.refreshIfStale()
        apps.refreshIfStale()
        projects.refreshIfStale()
        plugins.refreshIfStale()
        contentSearch.syncNotesIfStale()
        let opens = UserDefaults.standard.integer(forKey: PanelController.tipOpensKey)
        UserDefaults.standard.set(opens + 1, forKey: PanelController.tipOpensKey)
        content.tip = Tips.pick(opens: opens, used: Set(UserDefaults.standard.stringArray(forKey: PanelController.usedFeaturesKey) ?? []))
        content.prepareForShow() // sizes the panel for its first results
        if let message = welcome {
            content.notice = message
            welcome = nil
        } else if let message = reminder?() {
            content.notice = message
        }
        if plugins.hasHooks(for: .open) { plugins.fire(.open, input: frontApp.name, environment: ["EUCLID_APP_ID": frontApp.id]) }
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
        files.cancel()
        plugins.cancelAnswers()
        content.didHide()
        anchor = nil
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// Top centre of the panel at full size: centred on the screen under the mouse,
    /// its middle at two thirds up. Growing and shrinking keep this point fixed.
    private func topCenter() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        let full = LauncherViewController.size
        return NSPoint(x: frame.midX, y: frame.minY + frame.height * 0.66 + full.height / 2)
    }

    /// Fit the panel to its results. Shrinking, the preview's width and anything while hidden snap at once;
    /// only growing taller eases (120 ms, Core Animation, so typing never waits on it), so new rows slide in
    /// instead of the panel jumping.
    private func resize(to size: NSSize) {
        let top = anchor ?? topCenter()
        let frame = NSRect(x: (top.x - size.width / 2).rounded(), y: (top.y - size.height).rounded(), width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        let grows = frame.width == panel.frame.width && frame.height > panel.frame.height
        if panel.isVisible, grows, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.panel.invalidateShadow() }
            }
        } else {
            panel.setFrame(frame, display: panel.isVisible)
            if panel.isVisible { panel.invalidateShadow() }
        }
    }
}
