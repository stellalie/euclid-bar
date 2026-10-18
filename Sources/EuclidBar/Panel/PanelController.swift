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
    private let bitbucket = BitbucketService()
    private let ranking: RankingService
    /// Where the panel's top edge sits while it's open: it grows and shrinks downwards from here.
    private var anchor: NSPoint?

    init(clipboard: ClipboardService, config: ConfigService, history: HistoryService) {
        self.clipboard = clipboard
        self.config = config
        self.history = history
        apps = BackgroundIndex(name: "apps", maxAge: .seconds(60)) { $0.searchItem(id: $1) }
        projects = BackgroundIndex(name: "projects", maxAge: .seconds(300)) { $0.searchItem(id: $1) }
        files = FileSearchService()
        contentSearch = ContentService(databaseURL: config.paths.contentDatabase)
        ranking = RankingService(databaseURL: config.paths.rankingDatabase)
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
        content.clip = { [unowned clipboard] id in clipboard.history.clip(id: id) }
        content.clipImage = { [unowned clipboard] clip in clipboard.image(for: clip) }
        content.onPasteText = { [weak self] text in self?.pasteText(text) }
        content.onOpenURL = { [weak self] url in
            self?.hide()
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
        content.onOpenNote = { [weak self] path in self?.openNote(path: path) }
        content.onPreferredSizeChange = { [weak self] size in self?.resize(to: size) }
        content.onRunAction = { [weak self] action, query in self?.run(action, query: query) }
        content.historyProvider = { [unowned history] in history.items }
        content.historyURL = { [unowned history] id in history.entry(id: id)?.url }
        content.favicon = { [unowned history] host in history.favicon(host: host) }
        content.bitbucketProvider = { [unowned bitbucket] in bitbucket.items }
        content.bitbucketItem = { [unowned bitbucket] id in bitbucket.entry(id: id) }
        content.contentSearch = { [unowned contentSearch] text in contentSearch.search(text) }
        content.contentBody = { [unowned contentSearch] ref in contentSearch.body(ref: ref) }
        contentSearch.onResults = { [weak self] text, hits in self?.content.setContentResults(hits, for: text) }
        bitbucket.onChange = { [weak self] in
            guard let self else { return }
            self.updateProblem()
            if self.panel.isVisible { self.content.refreshAfterExternalChange() }
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
            self.contentSearch.indexPages(from: self.history.entries)
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
        content.theme = Theme(settings.appearance)
        contentSearch.configure(vault: settings.obsidianVault, pagesEnabled: settings.pagesEnabled,
                                pagesLimit: settings.pagesLimit, excludedHosts: settings.pagesExcludedHosts)
        if settings.pagesEnabled { contentSearch.indexPages(from: history.entries) }
        bitbucket.configure(settings.bitbucket, shell: settings.shellPath, environment: settings.environment)
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

    private func updateProblem() {
        content.problem = config.problemSummary ?? history.problem ?? bitbucket.problem
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
        CommandRunner.runInBackground(shell: shell, command: action.run, query: query,
                                      pathPrefix: config.paths.binDirectory.path, baseEnvironment: env,
                                      completion: completion)
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

    func show() {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("show")
        anchor = topCenter()
        history.refreshIfStale()
        apps.refreshIfStale()
        projects.refreshIfStale()
        bitbucket.refreshIfStale()
        contentSearch.syncNotesIfStale()
        content.prepareForShow() // sizes the panel for its first results
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

    /// Fit the panel to its results. Instant while hidden; a quick 80 ms ease while visible,
    /// animated by Core Animation so typing never waits on it.
    private func resize(to size: NSSize) {
        let top = anchor ?? topCenter()
        let frame = NSRect(x: (top.x - size.width / 2).rounded(), y: (top.y - size.height).rounded(), width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.panel.invalidateShadow() }
            }
        } else {
            panel.setFrame(frame, display: false)
        }
    }
}
