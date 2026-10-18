import AppKit
import Carbon.HIToolbox
import EuclidCore

@MainActor
final class LauncherViewController: NSViewController {
    /// Largest size without the preview. The panel shrinks to fit fewer results.
    static let size = NSSize(width: 680, height: 440)
    static let previewWidth: CGFloat = 400

    // Wiring (set by PanelController).
    var onClose: (() -> Void)?
    var onPaste: ((Int) -> Void)?
    var onCopy: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onRunAction: ((Action, _ query: String) -> Void)?
    var onOpenHistory: ((Int) -> Void)?
    var onCopyHistory: ((Int) -> Void)?
    var onOpenApp: ((String) -> Void)?
    var onOpenProject: ((String) -> Void)?
    var onOpenFile: ((String) -> Void)?
    /// Open a URL (a Bitbucket PR, an indexed page) in the default browser.
    var onOpenURL: ((String) -> Void)?
    var onOpenNote: ((String) -> Void)?
    /// Put text on the pasteboard and close (a path, a calculator answer).
    var onCopyText: ((String) -> Void)?
    /// Paste text into the previous app (a snippet).
    var onPasteText: ((String) -> Void)?
    /// The panel should take this size (it grows with the results, and for the preview).
    var onPreferredSizeChange: ((NSSize) -> Void)?
    /// Browser history (searched only when there's a query).
    var historyProvider: () -> [SearchItem] = { [] }
    var historyURL: (Int) -> String? = { _ in nil }
    var favicon: (_ host: String) -> NSImage? = { _ in nil }
    /// Installed apps (`subtitle` = path) and git repos.
    var appsProvider: () -> [SearchItem] = { [] }
    var projectsProvider: () -> [SearchItem] = { [] }
    var project: (Int) -> ProjectEntry? = { _ in nil }
    var bitbucketProvider: () -> [SearchItem] = { [] }
    var bitbucketItem: (Int) -> BitbucketItem? = { _ in nil }
    var clip: (Int) -> Clip? = { _ in nil }
    var clipImage: (Clip) -> NSImage? = { _ in nil }
    /// Starts an async file search; results come back through `setFileResults`.
    var fileSearch: ((String) -> Void)?
    /// Starts an async page/note text search; results come back through `setContentResults`.
    var contentSearch: ((String) -> Void)?
    /// Stored text of an indexed page or note, for the preview.
    var contentBody: (String) -> String? = { _ in nil }
    var ranking: RankingService?

    var aliases = Aliases() { didSet { if isViewLoaded { refreshAfterExternalChange() } } }
    var favorites: [String] = [] { didSet { if isViewLoaded { refreshAfterExternalChange() } } }
    var snippets: [Snippet] = [] {
        didSet {
            snippetItems = snippets.enumerated().map { $0.element.searchItem(id: $0.offset) }
            if isViewLoaded { refreshAfterExternalChange() }
        }
    }
    var theme = Theme() { didSet { if isViewLoaded { applyTheme() } } }

    /// Enabled actions from config, in order.
    var actions: [Action] = [] { didSet { if isViewLoaded { refreshAfterExternalChange() } } }
    /// Persistent message (e.g. config problem) shown in the footer instead of hints.
    var problem: String? { didSet { if isViewLoaded { updateFooter() } } }
    /// One-off message (e.g. last action failed). Cleared when the panel hides.
    var notice: String? { didSet { if isViewLoaded { updateFooter() } } }

    private enum Mode: Equatable {
        case search
        /// ⌘K list. Remembers the query (actions run on it) and the clip that was selected.
        case actions(query: String, clipID: Int?)
    }
    private var mode = Mode.search

    private let itemsProvider: () -> [SearchItem]
    private var snippetItems: [SearchItem] = []
    private var rows: [Row] = []
    /// Rows from the instant sources; async hits (pages, notes, files) are appended below them.
    private var baseRows: [Row] = []
    private var fileHits: (query: String, hits: [FileHit]) = ("", [])
    private var contentHits: (query: String, hits: [ContentHit]) = ("", [])
    private var keyMonitor: Any?
    private var previewOpen = false
    /// "12,431 items · 0.6 ms", refreshed on every search.
    private var lastStats = ""

    private let background = NSView()
    private var effectView: NSView?
    private var installedGlass: Bool?
    private let content = NSView()
    private let searchField = NSTextField()
    private let modeLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let hints = HintBar()
    private let stats = NSTextField(labelWithString: "")
    private let preview = PreviewView()
    private let previewDivider = NSBox()
    private var listTrailing: NSLayoutConstraint!

    /// Space above and below the list: search field and footer.
    private static let chrome: CGFloat = 60 + 34

    init(items: @escaping () -> [SearchItem]) {
        self.itemsProvider = items
        super.init(nibName: nil, bundle: nil)
        IconCache.shared.onLoad = { [weak self] path in self?.iconLoaded(path) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        view = root
        background.frame = root.bounds
        background.autoresizingMask = [.width, .height]
        root.addSubview(background)
        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.delegate = self

        modeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modeLabel.textColor = .secondaryLabelColor
        modeLabel.lineBreakMode = .byTruncatingMiddle
        modeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let divider = NSBox()
        divider.boxType = .separator

        let column = NSTableColumn(identifier: .init("main"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        tableView.refusesFirstResponder = true // typing always stays in the search field

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        scrollView.automaticallyAdjustsContentInsets = false

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .systemOrange
        footer.lineBreakMode = .byTruncatingTail
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stats.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        stats.textColor = .tertiaryLabelColor
        stats.alignment = .right
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        stats.setContentHuggingPriority(.required, for: .horizontal)
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        previewDivider.boxType = .separator
        preview.isHidden = true
        previewDivider.isHidden = true

        for v in [searchField, modeLabel, divider, scrollView, emptyLabel, footerDivider, footer, hints, stats, preview, previewDivider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        listTrailing = scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: modeLabel.leadingAnchor, constant: -8),

            modeLabel.firstBaselineAnchor.constraint(equalTo: searchField.firstBaselineAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            modeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: 59),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: Self.size.width).withPriority(.defaultHigh),
            listTrailing,
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            previewDivider.topAnchor.constraint(equalTo: divider.bottomAnchor),
            previewDivider.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            previewDivider.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            previewDivider.widthAnchor.constraint(equalToConstant: 1),
            preview.topAnchor.constraint(equalTo: divider.bottomAnchor),
            preview.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            preview.leadingAnchor.constraint(equalTo: previewDivider.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -33),

            hints.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hints.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -16.5),
            hints.trailingAnchor.constraint(lessThanOrEqualTo: stats.leadingAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.centerYAnchor.constraint(equalTo: hints.centerYAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: stats.leadingAnchor, constant: -12),
            stats.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stats.centerYAnchor.constraint(equalTo: hints.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        applyTheme()
        installKeyMonitor()
        enterSearchMode(query: "")
    }

    /// Background (Liquid Glass or blur), sizes and fonts from `[appearance]`.
    private func applyTheme() {
        searchField.font = .systemFont(ofSize: theme.querySize, weight: .regular)
        if installedGlass != theme.glass { installBackground(glass: theme.glass) }
        tableView.reloadData()
        if !rows.isEmpty { select(row: max(tableView.selectedRow, 0)) }
        updateFooter()
        notifySize()
    }

    private func installBackground(glass: Bool) {
        installedGlass = glass
        effectView?.removeFromSuperview()
        content.removeFromSuperview()
        let effect: NSView
        #if compiler(>=6.2)
        if glass, #available(macOS 26, *) {
            let g = NSGlassEffectView(frame: background.bounds)
            g.cornerRadius = 16
            g.contentView = content
            effect = g
        } else {
            effect = Self.blur()
            effect.addSubview(content)
        }
        #else
        effect = Self.blur()
        effect.addSubview(content)
        #endif
        effect.frame = background.bounds
        effect.autoresizingMask = [.width, .height]
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(effect)
        effectView = effect
    }

    private static func blur() -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    // MARK: - Lifecycle

    /// Called right before the panel is shown: fresh search, focused field.
    func prepareForShow() {
        setPreview(open: false)
        enterSearchMode(query: "")
        view.window?.makeFirstResponder(searchField)
    }

    func didHide() {
        notice = nil
        setPreview(open: false)
    }

    /// History or config changed while the panel may be visible: refresh, keep the selection if possible.
    func refreshAfterExternalChange() {
        guard isViewLoaded else { return }
        let previous = selectedRow.map(\.key)
        runSearch()
        if let previous, let i = rows.firstIndex(where: { $0.key == previous }) { select(row: i) }
    }

    // MARK: - Demo (driven by `euclid-bar --render-demo`)

    func demoSetQuery(_ text: String) { searchField.stringValue = text; runSearch() }
    func demoToggleActions() { if case .actions = mode { enterSearchMode(query: query) } else { enterActionsMode() } }
    /// Select the nth result, not counting section headers.
    func demoSelect(row: Int) {
        let selectable = rows.indices.filter { !rows[$0].isHeader }
        if selectable.indices.contains(row) { select(row: selectable[row]) }
    }
    var demoRowCount: Int { rows.filter { !$0.isHeader }.count }

    // MARK: - Modes

    private func enterSearchMode(query: String) {
        mode = .search
        searchField.stringValue = query
        searchField.placeholderString = "Search apps, projects, files, clipboard, history…"
        modeLabel.stringValue = ""
        runSearch()
        searchField.currentEditor()?.moveToEndOfDocument(nil)
    }

    private func enterActionsMode() {
        let clipID: Int? = if case .clip(let item)? = selectedRow { item.id } else { nil }
        let query = searchField.stringValue
        mode = .actions(query: query, clipID: clipID)
        searchField.stringValue = ""
        searchField.placeholderString = "Filter actions…"
        modeLabel.stringValue = query.isEmpty ? "Actions" : "Actions · “\(query)”"
        runSearch()
    }

    /// The text actions run on: the typed query (remembered while in ⌘K).
    private var query: String {
        if case .actions(let q, _) = mode { return q }
        return searchField.stringValue
    }

    // MARK: - Search

    private func runSearch() {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("search")
        let text = searchField.stringValue
        var searched = 0

        switch mode {
        case .search:
            let all = itemsProvider()
            if text.isEmpty {
                let clips = FuzzyMatcher.search(text, in: all).map(Row.clip)
                baseRows = suggestions() + (clips.isEmpty ? [] : [.header("Clipboard")] + clips)
                searched = all.count
            } else {
                let ranked = rankedRows(for: text, clips: all)
                searched = ranked.searched
                // Nothing matched: offer the actions instead, Raycast-style.
                if !ranked.rows.isEmpty { baseRows = ranked.rows.sectioned() }
                else if actions.isEmpty { baseRows = [] }
                else { baseRows = [.header("Use “\(text)” with…")] + actionRows(filter: "") }
            }
            // Keep the last async hits that still match while the new ones load, so
            // the bottom of the list doesn't blink on every keystroke.
            if fileHits.query != text {
                fileHits = (text, text.isEmpty ? [] : fileHits.hits.filter { FuzzyMatcher.score(query: text, in: $0.name) != nil })
            }
            if contentHits.query != text {
                let keep = !text.isEmpty && text.hasPrefix(contentHits.query) && !contentHits.query.isEmpty
                contentHits = (text, keep ? contentHits.hits.filter {
                    FuzzyMatcher.score(query: text, in: "\($0.title) \($0.snippet)") != nil
                } : [])
            }
            fileSearch?(text)
            contentSearch?(text)
            rows = withAsyncRows(baseRows)
            emptyLabel.stringValue = all.isEmpty && text.isEmpty ? "Copy something — it will show up here." : "No matches"

        case .actions(_, let clipID):
            fileSearch?("")
            contentSearch?("")
            rows = actionRows(filter: text)
            if let clipID {
                rows += Row.Builtin.allCases
                    .filter { text.isEmpty || FuzzyMatcher.score(query: text, in: $0.rawValue) != nil }
                    .map { .builtin($0, clipID: clipID) }
            }
            searched = actions.count
            emptyLabel.stringValue = actions.isEmpty && clipID == nil
                ? "No actions yet — add [[action]] blocks to config.toml" : "No matching actions"
        }

        tableView.reloadData()
        select(row: 0)
        emptyLabel.isHidden = !rows.isEmpty
        let elapsed = ContinuousClock.now - start
        lastStats = Self.stats(items: searched, elapsed: elapsed)
        updateFooter()
        notifySize()
        tableView.displayIfNeeded()
        signposter.endInterval("search", state)
        perfLog.notice("search -> \(self.rows.count) rows in \(String(describing: elapsed), privacy: .public)")
    }

    /// "12,431 items · 0.42 ms"
    static func stats(items: Int, elapsed: Duration) -> String {
        let (s, atto) = elapsed.components
        let ms = Double(s) * 1000 + Double(atto) / 1e15
        let time = ms < 10 ? String(format: "%.2f ms", ms) : String(format: "%.0f ms", ms)
        return "\(items.formatted()) items · \(time)"
    }

    /// Async hits go last, so they never push the instant rows around.
    private func withAsyncRows(_ base: [Row]) -> [Row] {
        var out = base
        let notes = contentHits.hits.filter { $0.kind == .note }, pages = contentHits.hits.filter { $0.kind == .page }
        if !notes.isEmpty { out += [.header("Notes")] + notes.map(Row.content) }
        if !pages.isEmpty { out += [.header("Pages")] + pages.map(Row.content) }
        if !fileHits.hits.isEmpty { out += [.header("Files")] + fileHits.hits.map(Row.file) }
        return out
    }

    /// Everything that matches, best first. A row's score is its text match, plus a
    /// bonus for sources you usually want (apps over clips), plus what it learned from
    /// your past picks for this query. Answers (calculator, conversions) and an exact
    /// alias or snippet keyword go first.
    private func rankedRows(for text: String, clips: [SearchItem]) -> (rows: [Row], searched: Int) {
        let learned = ranking?.bonuses(for: text) ?? [:]
        var scored: [(score: Int, source: Int, order: Int, row: Row)] = []
        var searched = 0
        func add(_ items: [SearchItem], limit: Int, source: Int, boost: Int, _ make: (SearchItem) -> Row?) {
            searched += items.count
            for (i, hit) in FuzzyMatcher.scoredSearch(text, in: items, limit: limit).enumerated() {
                guard let row = make(hit.item) else { continue }
                let bonus = row.learnKey.flatMap { learned[$0] } ?? 0
                scored.append((hit.score + boost + bonus, source, i, row))
            }
        }
        add(appsProvider(), limit: 20, source: 0, boost: 80) { .app($0) }
        add(projectsProvider(), limit: 20, source: 1, boost: 40) { project($0.id).map(Row.project) }
        add(bitbucketProvider(), limit: 15, source: 2, boost: 30) { bitbucketItem($0.id).map(Row.bitbucket) }
        add(snippetItems, limit: 9, source: 3, boost: 20) { item in snippets.indices.contains(item.id) ? .snippet(item, snippets[item.id]) : nil }
        let actionItems = actions.enumerated().map { SearchItem(id: $0.offset, title: $0.element.name) }
        add(actionItems, limit: 9, source: 4, boost: -50) { .action(number: $0.id + 1, actions[$0.id]) }
        add(clips, limit: 50, source: 5, boost: 0) { .clip($0) }
        add(historyProvider(), limit: 30, source: 6, boost: 0) { .history($0) }

        var ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.source != $1.source ? $0.source < $1.source : $0.order < $1.order
        }.map(\.row)

        var pinned: [Row] = []
        if let result = Calculator.evaluate(text) { pinned.append(.calc(result, expression: text)) }
        pinned += DevTransforms.evaluate(text).map(Row.transform)
        var top: [Row] = []
        if let match = aliases.match(text), let row = resolve(title: match.target, argument: match.argument) { top.append(row) }
        if let i = snippets.firstIndex(where: { $0.keyword?.lowercased() == text.lowercased() }) {
            top.append(.snippet(snippetItems[i], snippets[i]))
        }
        let topKeys = Set(top.map(\.key))
        ranked.removeAll { topKeys.contains($0.key) }
        return (top + pinned + Array(ranked.prefix(40)), searched)
    }

    /// The empty box: favourites from config, then what you pick most, then PRs waiting on your review.
    private func suggestions() -> [Row] {
        var picks = favorites.compactMap { resolve(title: $0, argument: nil) }
        var keys = Set(picks.map(\.key))
        for key in ranking?.top(8) ?? [] where picks.count < favorites.count + 3 {
            guard let row = resolve(key: key), keys.insert(row.key).inserted else { continue }
            picks.append(row)
        }
        var out: [Row] = picks.isEmpty ? [] : [.header("Suggestions")] + picks
        let reviews = bitbucketProvider().compactMap { bitbucketItem($0.id) }.filter { $0.kind == .reviewPR }.prefix(3)
        if !reviews.isEmpty { out += [.header("Waiting on your review")] + reviews.map(Row.bitbucket) }
        return out
    }

    /// An alias or favourite target, by name: an action, app, project or snippet.
    private func resolve(title: String, argument: String?) -> Row? {
        let t = title.lowercased()
        if let i = actions.firstIndex(where: { $0.name.lowercased() == t }) {
            return argument.map { .aliasAction(actions[i], argument: $0) } ?? .action(number: i + 1, actions[i])
        }
        guard argument == nil else { return nil } // only actions take text
        if let app = appsProvider().first(where: { $0.title.lowercased() == t }) { return .app(app) }
        if let item = projectsProvider().first(where: { $0.title.lowercased() == t }), let p = project(item.id) {
            return .project(p)
        }
        if let i = snippets.firstIndex(where: { $0.name.lowercased() == t }) { return .snippet(snippetItems[i], snippets[i]) }
        return nil
    }

    /// A learned pick, by its `learnKey`, if it still exists.
    private func resolve(key: String) -> Row? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let kind = key[..<colon], value = String(key[key.index(after: colon)...])
        switch kind {
        case "app": return appsProvider().first { $0.subtitle == value }.map(Row.app)
        case "proj":
            return projectsProvider().compactMap { project($0.id) }.first { $0.path == value }.map(Row.project)
        case "file":
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: value, isDirectory: &isDir) else { return nil }
            return .file(FileHit(path: value, isFolder: isDir.boolValue))
        case "action":
            return actions.firstIndex { $0.name == value }.map { .action(number: $0 + 1, actions[$0]) }
        case "snippet":
            return snippets.firstIndex { $0.name == value }.map { .snippet(snippetItems[$0], snippets[$0]) }
        case "bb":
            return bitbucketProvider().compactMap { bitbucketItem($0.id) }.first { $0.url == value }.map(Row.bitbucket)
        default: return nil
        }
    }

    /// Spotlight answered. Append below the instant rows, keeping the selection.
    func setFileResults(_ hits: [FileHit], for text: String) {
        guard isViewLoaded, case .search = mode, text == searchField.stringValue else { return }
        fileHits = (text, hits)
        asyncResultsChanged()
    }

    /// The page/note index answered.
    func setContentResults(_ hits: [ContentHit], for text: String) {
        guard isViewLoaded, case .search = mode, text == searchField.stringValue else { return }
        contentHits = (text, hits)
        asyncResultsChanged()
    }

    private func asyncResultsChanged() {
        let previous = selectedRow.map(\.key)
        let newRows = withAsyncRows(baseRows)
        guard newRows.map(\.key) != rows.map(\.key) else { return }
        rows = newRows
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        select(row: previous.flatMap { key in rows.firstIndex { $0.key == key } } ?? 0)
        notifySize()
    }

    private func iconLoaded(_ path: String) {
        guard isViewLoaded else { return }
        let changed = IndexSet(rows.indices.filter { rows[$0].path == path || iconPath(rows[$0]) == path })
        guard !changed.isEmpty else { return }
        tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
    }

    private func actionRows(filter: String) -> [Row] {
        actions.enumerated().compactMap { i, action in
            guard filter.isEmpty || FuzzyMatcher.score(query: filter, in: action.name) != nil else { return nil }
            return .action(number: i + 1, action)
        }
    }

    // MARK: - Size

    /// Just tall enough for the rows (up to the full size); full size and wider with the preview.
    private var preferredSize: NSSize {
        let width = Self.size.width + (previewOpen ? Self.previewWidth : 0)
        if previewOpen { return NSSize(width: width, height: Self.size.height) }
        let list = rows.isEmpty ? 64 : rows.reduce(0) { $0 + height(of: $1) } + 8
        return NSSize(width: width, height: min(Self.chrome + list, Self.size.height))
    }

    private func notifySize() { onPreferredSizeChange?(preferredSize) }

    private func height(of row: Row) -> CGFloat { row.isHeader ? theme.headerHeight : theme.rowHeight }

    // MARK: - Preview

    private func setPreview(open: Bool) {
        guard open != previewOpen else { return }
        previewOpen = open
        preview.isHidden = !open
        previewDivider.isHidden = !open
        listTrailing.isActive = !open
        if open { updatePreview() } else { preview.clear() }
        updateFooter()
        notifySize()
    }

    private func updatePreview() {
        guard previewOpen else { return }
        preview.show(selectedRow.map(previewContent) ?? .none)
    }

    private func previewContent(for row: Row) -> PreviewView.Content {
        switch row {
        case .header: return .none
        case .clip(let item):
            guard let c = clip(item.id) else { return .none }
            let facts = [("From", c.sourceName ?? "—"), ("Copied", RelativeAge.short(c.lastUsedAt)), ("Used", "\(c.useCount)×")]
            switch c.kind {
            case .image:
                return clipImage(c).map { .image($0, title: item.title) } ?? .none
            case .files:
                if c.paths.count == 1 { return .quickLook(URL(fileURLWithPath: c.paths[0])) }
                return .text(title: item.title, facts: facts, body: c.paths.joined(separator: "\n"), code: true)
            case .text:
                let pretty = DevTransforms.json(c.content).first?.value
                return .text(title: "", facts: facts, body: pretty ?? c.content, code: true)
            }
        case .history(let item):
            let url = historyURL(item.id) ?? ""
            let body = contentBody(url) ?? ""
            return .text(title: item.title, facts: [("URL", url), ("Where", ResultCell.historySubtitle(item))], body: body, code: false)
        case .action(_, let a), .aliasAction(let a, _):
            return .text(title: a.name, facts: [("Runs", a.run)], body: "", code: false)
        case .builtin(let b, _): return .text(title: b.rawValue, facts: [("Key", b.hint)], body: "", code: false)
        case .app(let item):
            return .quickLook(URL(fileURLWithPath: item.subtitle))
        case .project(let p):
            let readme = ["README.md", "readme.md", "README", "README.txt"].lazy
                .compactMap { try? String(contentsOfFile: (p.path as NSString).appendingPathComponent($0), encoding: .utf8) }.first
            return .text(title: p.name, facts: [("Path", ProjectScanner.abbreviate(p.path))], body: readme ?? "", code: false)
        case .file(let f): return .quickLook(URL(fileURLWithPath: f.path))
        case .calc(let r, let expression): return .text(title: r.display, facts: [("Expression", expression)], body: "", code: false)
        case .transform(let t): return .text(title: t.label, facts: [], body: t.value, code: true)
        case .snippet(_, let s):
            return .text(title: s.name, facts: s.keyword.map { [("Keyword", $0)] } ?? [], body: s.expanded(clipboard: Self.clipboardText), code: false)
        case .content(let c):
            let body = contentBody(c.ref) ?? c.snippet
            return .text(title: c.title, facts: [(c.kind == .note ? "Note" : "URL", c.ref)], body: body, code: false)
        case .bitbucket(let b):
            let updated = b.updated.map { RelativeAge.short($0) } ?? "—"
            return .text(title: b.title, facts: [("Where", b.subtitle), ("Updated", updated), ("URL", b.url)], body: "", code: false)
        }
    }

    nonisolated static func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }

    // MARK: - Footer

    private func updateFooter() {
        stats.isHidden = !theme.showSpeed || lastStats.isEmpty
        stats.stringValue = lastStats
        if let message = notice ?? problem {
            footer.stringValue = message
            footer.isHidden = false
            hints.isHidden = true
            return
        }
        footer.isHidden = true
        hints.isHidden = false
        typealias H = HintBar.Hint
        switch mode {
        case .search:
            var list: [H] = []
            switch selectedRow {
            case .clip?, .snippet?: list.append(H(key: "↵", label: "Paste"))
            case .history(let item)?: list.append(H(key: "↵", label: "Open in \(item.subtitle.components(separatedBy: " · ").first ?? "browser")"))
            case .app?, .project?, .file?, .bitbucket?, .content?: list.append(H(key: "↵", label: "Open"))
            case .calc?, .transform?: list.append(H(key: "↵", label: "Copy"))
            case nil, .header?: break
            default: list.append(H(key: "↵", label: "Run"))
            }
            if selectedRow != nil { list.append(H(key: previewOpen ? "esc" : "→", label: previewOpen ? "Close preview" : "Preview")) }
            if let first = actions.first { list.append(H(key: "⌘↵", label: first.name)) }
            list.append(H(key: "⌘K", label: "Actions"))
            if case .clip? = selectedRow { list += [H(key: "⌘C", label: "Copy"), H(key: "⌘⌫", label: "Delete")] }
            if case .history? = selectedRow { list.append(H(key: "⌘C", label: "Copy URL")) }
            if case .bitbucket? = selectedRow { list.append(H(key: "⌘C", label: "Copy URL")) }
            if selectedRow?.path != nil { list.append(H(key: "⌘C", label: "Copy path")) }
            hints.set(list)
        case .actions:
            hints.set([H(key: "↵", label: "Run"), H(key: "1–9", label: "Run"), H(key: "esc", label: "Back")])
        }
    }

    // MARK: - Selection & activation

    private var selectedRow: Row? {
        rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow] : nil
    }

    /// Select `row`, or the nearest result in `direction` when it's a header.
    private func select(row: Int, direction: Int = 1) {
        guard !rows.isEmpty else { return }
        var r = max(0, min(row, rows.count - 1))
        while rows.indices.contains(r), rows[r].isHeader { r += direction }
        if !rows.indices.contains(r) { // ran off the end: go the other way
            r = max(0, min(row, rows.count - 1))
            while rows.indices.contains(r), rows[r].isHeader { r -= direction }
        }
        guard rows.indices.contains(r) else { return }
        tableView.selectRowIndexes([r], byExtendingSelection: false)
        // Keep the header above the first result in view.
        tableView.scrollRowToVisible(r > 0 && rows[r - 1].isHeader ? r - 1 : r)
        tableView.scrollRowToVisible(r)
        updateFooter()
        updatePreview()
    }

    @objc private func activateSelection() {
        guard let row = selectedRow else { return }
        if case .search = mode, let key = row.learnKey { ranking?.record(query: query, key: key) }
        switch row {
        case .header: return
        case .clip(let item): onPaste?(item.id)
        case .history(let item): onOpenHistory?(item.id)
        case .action(_, let action): onRunAction?(action, query)
        case .aliasAction(let action, let argument): onRunAction?(action, argument)
        case .app(let item): onOpenApp?(item.subtitle)
        case .project(let p): onOpenProject?(p.path)
        case .file(let f): onOpenFile?(f.path)
        case .calc(let result, _): onCopyText?(result.text)
        case .transform(let t): onCopyText?(t.value)
        case .snippet(_, let s): onPasteText?(s.expanded(clipboard: Self.clipboardText))
        case .content(let c): c.kind == .note ? onOpenNote?(c.ref) : onOpenURL?(c.ref)
        case .bitbucket(let b): onOpenURL?(b.url)
        case .builtin(.paste, let id): onPaste?(id)
        case .builtin(.copy, let id): onCopy?(id)
        case .builtin(.delete, let id):
            onDelete?(id)
            enterSearchMode(query: query)
        }
    }

    /// ⌘1–⌘9 (any mode) or plain 1–9 (in ⌘K): run the Nth action.
    private func runAction(number n: Int) {
        guard actions.indices.contains(n - 1) else { NSSound.beep(); return }
        onRunAction?(actions[n - 1], query)
    }

    // MARK: - Keys

    /// Key equivalents (⌘-combos) and digits bypass the text field delegate, so handle them here.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            let keyCode = Int(event.keyCode)
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let window = event.window.map(ObjectIdentifier.init)
            let consumed = MainActor.assumeIsolated {
                self?.handleKey(keyCode: keyCode, mods: mods, window: window) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func handleKey(keyCode: Int, mods: NSEvent.ModifierFlags, window: ObjectIdentifier?) -> Bool {
        guard let own = view.window, window == ObjectIdentifier(own) else { return false }
        let digit = HotkeyBinding.digitKeyCodes.firstIndex(of: keyCode).flatMap { $0 == 0 ? nil : $0 }
        let inActions = if case .actions = mode { true } else { false }

        switch (mods, keyCode) {
        case (.command, kVK_ANSI_K):
            inActions ? enterSearchMode(query: query) : enterActionsMode()
            return true
        case (.command, kVK_ANSI_Y):
            guard !inActions else { return false }
            setPreview(open: !previewOpen)
            return true
        case (.command, kVK_Return), (.command, kVK_ANSI_KeypadEnter):
            runAction(number: 1)
            return true
        case (.command, _) where digit != nil:
            runAction(number: digit!)
            return true
        case ([], _) where digit != nil && inActions:
            runAction(number: digit!)
            return true
        case (.command, kVK_ANSI_C):
            guard !inActions else { return false }
            if let editor = searchField.currentEditor(), editor.selectedRange.length > 0 { return false } // normal text copy
            switch selectedRow {
            case .clip(let item)?: onCopy?(item.id)
            case .history(let item)?: onCopyHistory?(item.id)
            case .calc(let result, _)?: onCopyText?(result.text)
            case .transform(let t)?: onCopyText?(t.value)
            case .bitbucket(let b)?: onCopyText?(b.url)
            case .content(let c)? where c.kind == .page: onCopyText?(c.ref)
            case .snippet(_, let s)?: onCopyText?(s.expanded(clipboard: Self.clipboardText))
            case let row? where row.path != nil: onCopyText?(row.path!)
            default: return false
            }
            return true
        case (.command, kVK_Delete):
            guard case .clip(let item)? = selectedRow, !inActions else { return false }
            let row = tableView.selectedRow
            onDelete?(item.id)
            select(row: row) // keep the cursor in place
            return true
        default:
            return false
        }
    }

    /// The file whose icon a row shows (beyond `Row.path`): a copied file's first path.
    private func iconPath(_ row: Row) -> String? {
        guard case .clip(let item) = row, let c = clip(item.id), c.kind == .files else { return nil }
        return c.paths.first
    }
}

extension LauncherViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { runSearch() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(row: tableView.selectedRow - 1, direction: -1)
        case #selector(NSResponder.moveDown(_:)): select(row: tableView.selectedRow + 1, direction: 1)
        case #selector(NSResponder.moveRight(_:)):
            // → at the end of the text opens the preview; anywhere else it moves the caret.
            let r = textView.selectedRange()
            guard !previewOpen, case .search = mode, selectedRow != nil, r.length == 0, r.location == (textView.string as NSString).length
            else { return false }
            setPreview(open: true)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            if previewOpen { setPreview(open: false) }
            else if case .actions = mode { enterSearchMode(query: query) }
            else { onClose?() }
        default: return false
        }
        return true
    }
}

extension LauncherViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) ? height(of: rows[row]) : theme.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !rows[row].isHeader }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ResultRowView()
        view.accent = theme.accent
        view.isHeader = rows[row].isHeader
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        if case .header(let title) = r {
            let cell = tableView.makeView(withIdentifier: SectionHeaderCell.id, owner: nil) as? SectionHeaderCell ?? SectionHeaderCell()
            cell.configure(title)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell ?? ResultCell()
        let inActions = if case .actions = mode { true } else { false }
        let highlight: String? = inActions ? searchField.stringValue : searchField.stringValue.isEmpty ? nil : searchField.stringValue
        let tint = Theme.tint(for: r)
        func show(_ symbol: String, image: NSImage? = nil, _ title: String, detail: String = "", _ accessory: String, plain: Bool = false) {
            cell.configure(icon: symbol, image: image, tint: tint, title: title, detail: detail, accessory: accessory,
                           highlight: plain ? nil : highlight, theme: theme)
        }
        switch r {
        case .header: break
        case .clip(let item):
            let c = clip(item.id)
            switch c?.kind {
            case .image?: show("photo", image: c.flatMap(clipImage), item.title, ResultCell.clipSubtitle(item))
            case .files?: show("doc.on.doc", image: c?.paths.first.flatMap { IconCache.shared.icon(forPath: $0) }, item.title, ResultCell.clipSubtitle(item))
            default: show("doc.on.clipboard", item.title, ResultCell.clipSubtitle(item))
            }
        case .history(let item):
            let host = URL(string: historyURL(item.id) ?? "")?.host()?.lowercased() ?? ""
            show("globe", image: favicon(host), item.title, ResultCell.historySubtitle(item))
        case .action(let n, let action):
            let key = n <= 9 ? (inActions ? "\(n)" : "⌘\(n)") : ""
            show("bolt.fill", action.name, tagged(key, title: action.name))
        case .aliasAction(let action, let argument):
            show("bolt.fill", action.name, detail: "“\(argument)”", "↵", plain: true)
        case .builtin(let b, _):
            show(b.icon, b.rawValue, b.hint)
        case .app(let item):
            show("app", image: IconCache.shared.icon(forPath: item.subtitle), item.title, tagged("Application", title: item.title))
        case .project(let p):
            show("folder", image: IconCache.shared.icon(forPath: p.path), p.name,
                 detail: ProjectScanner.abbreviate((p.path as NSString).deletingLastPathComponent), tagged("Project", title: p.name))
        case .file(let f):
            show(f.isFolder ? "folder" : "doc", image: IconCache.shared.icon(forPath: f.path), f.name, detail: f.folder,
                 f.isFolder ? "Folder" : "File")
        case .calc(let result, let expression):
            show("equal", result.display, detail: expression, "Calculator", plain: true)
        case .transform(let t):
            show("wand.and.stars", image: t.color.map { Self.swatch($0) }, t.display, t.label, plain: true)
        case .snippet(let item, let s):
            show("text.quote", s.name, detail: s.keyword ?? "", tagged("Snippet", title: item.title))
        case .content(let c):
            show(c.kind == .note ? "note.text" : "doc.richtext", c.title, detail: c.snippet, c.kind == .note ? "Note" : "Page", plain: true)
        case .bitbucket(let b):
            let (symbol, label) = switch b.kind {
            case .reviewPR: ("arrow.triangle.pull", "Review")
            case .myPR: ("arrow.triangle.pull", "Your PR")
            case .repo: ("shippingbox", "Repo")
            }
            show(symbol, b.title, detail: b.subtitle, label)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
        updatePreview()
    }

    /// "Application" → "code · Application" when it has an alias.
    private func tagged(_ label: String, title: String) -> String {
        guard let alias = aliases.alias(for: title) else { return label }
        return label.isEmpty ? alias : "\(alias) · \(label)"
    }

    /// A rounded colour swatch for hex/rgb conversions.
    private static func swatch(_ c: DevTransforms.RGB) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            path.stroke()
            return true
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
