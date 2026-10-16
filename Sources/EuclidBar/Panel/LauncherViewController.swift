import AppKit
import Carbon.HIToolbox
import EuclidCore

/// One row in the results list.
enum Row {
    case clip(SearchItem)
    case history(SearchItem)
    /// `number` is the 1-based position in the action list (⌘1 = 1).
    case action(number: Int, Action)
    /// An action reached by its alias: "gh swift testing" runs it on "swift testing".
    case aliasAction(Action, argument: String)
    case builtin(Builtin, clipID: Int)
    /// `subtitle` is the app's path.
    case app(SearchItem)
    case project(ProjectEntry)
    case file(FileHit)
    case calc(Calculator.Result, expression: String)

    /// Stable identity for learned ranking. Nil for things that aren't worth learning
    /// (clips already reorder themselves on use; a calculation is never the same twice).
    var learnKey: String? {
        switch self {
        case .app(let item): "app:\(item.subtitle)"
        case .project(let p): "proj:\(p.path)"
        case .file(let f): "file:\(f.path)"
        case .action(_, let a), .aliasAction(let a, _): "action:\(a.name)"
        case .clip, .history, .builtin, .calc: nil
        }
    }

    /// The path a row stands for, for ⌘C and icons.
    var path: String? {
        switch self {
        case .app(let item): item.subtitle
        case .project(let p): p.path
        case .file(let f): f.path
        default: nil
        }
    }

    enum Builtin: String, CaseIterable {
        case paste = "Paste clip", copy = "Copy clip", delete = "Delete clip"
        var icon: String { ["Paste clip": "text.insert", "Copy clip": "doc.on.doc", "Delete clip": "trash"][rawValue]! }
        var hint: String { ["Paste clip": "↵", "Copy clip": "⌘C", "Delete clip": "⌘⌫"][rawValue]! }
    }
}

@MainActor
final class LauncherViewController: NSViewController {
    static let size = NSSize(width: 680, height: 440)

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
    /// Put text on the pasteboard and close (a path, a calculator answer).
    var onCopyText: ((String) -> Void)?
    /// Browser history (searched only when there's a query).
    var historyProvider: () -> [SearchItem] = { [] }
    /// Installed apps (`subtitle` = path) and git repos.
    var appsProvider: () -> [SearchItem] = { [] }
    var projectsProvider: () -> [SearchItem] = { [] }
    var project: (Int) -> ProjectEntry? = { _ in nil }
    /// Starts an async file search; results come back through `setFileResults`.
    var fileSearch: ((String) -> Void)?
    var ranking: RankingService?

    var aliases = Aliases() { didSet { if isViewLoaded { refreshAfterExternalChange() } } }
    var favorites: [String] = [] { didSet { if isViewLoaded { refreshAfterExternalChange() } } }

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
    private var rows: [Row] = []
    /// Rows from the instant sources; async file hits are appended below them.
    private var baseRows: [Row] = []
    private var fileHits: (query: String, hits: [FileHit]) = ("", [])
    private var keyMonitor: Any?

    private let searchField = NSTextField()
    private let modeLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")

    init(items: @escaping () -> [SearchItem]) {
        self.itemsProvider = items
        super.init(nibName: nil, bundle: nil)
        IconCache.shared.onLoad = { [weak self] path in self?.iconLoaded(path) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        view = root

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 22, weight: .regular)
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
        tableView.style = .inset
        tableView.rowHeight = 40
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

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footer.font = .systemFont(ofSize: 11)
        footer.lineBreakMode = .byTruncatingTail
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor

        for v in [searchField, modeLabel, divider, scrollView, emptyLabel, footerDivider, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: modeLabel.leadingAnchor, constant: -8),

            modeLabel.firstBaselineAnchor.constraint(equalTo: searchField.firstBaselineAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            modeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -4),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        installKeyMonitor()
        enterSearchMode(query: "")
    }

    // MARK: - Lifecycle

    /// Called right before the panel is shown: fresh search, focused field.
    func prepareForShow() {
        enterSearchMode(query: "")
        view.window?.makeFirstResponder(searchField)
    }

    func didHide() { notice = nil }

    /// History or config changed while the panel may be visible: refresh, keep the selection if possible.
    func refreshAfterExternalChange() {
        guard isViewLoaded else { return }
        let previous = selectedRow.map(rowKey)
        runSearch()
        if let previous, let i = rows.firstIndex(where: { rowKey($0) == previous }) { select(row: i) }
    }

    // MARK: - Demo (driven by `euclid-bar --render-demo`)

    func demoSetQuery(_ text: String) { searchField.stringValue = text; runSearch() }
    func demoToggleActions() { if case .actions = mode { enterSearchMode(query: query) } else { enterActionsMode() } }
    func demoSelect(row: Int) { select(row: row) }
    var demoRowCount: Int { rows.count }

    // MARK: - Modes

    private func enterSearchMode(query: String) {
        mode = .search
        searchField.stringValue = query
        searchField.placeholderString = "Search apps, projects, files, clipboard and history…"
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

        switch mode {
        case .search:
            let all = itemsProvider()
            if text.isEmpty {
                baseRows = suggestions() + FuzzyMatcher.search(text, in: all).map(Row.clip)
            } else {
                baseRows = rankedRows(for: text, clips: all)
                // Nothing matched: offer the actions instead, Raycast-style.
                if baseRows.isEmpty { baseRows = actionRows(filter: "") }
            }
            if fileHits.query != text { fileHits = (text, []) }
            fileSearch?(text)
            rows = baseRows + fileHits.hits.map(Row.file)
            emptyLabel.stringValue = all.isEmpty && text.isEmpty ? "Copy something — it will show up here." : "No matches"

        case .actions(_, let clipID):
            fileSearch?("")
            rows = actionRows(filter: text)
            if let clipID {
                rows += Row.Builtin.allCases
                    .filter { text.isEmpty || FuzzyMatcher.score(query: text, in: $0.rawValue) != nil }
                    .map { .builtin($0, clipID: clipID) }
            }
            emptyLabel.stringValue = actions.isEmpty && clipID == nil
                ? "No actions yet — add [[action]] blocks to config.toml" : "No matching actions"
        }

        tableView.reloadData()
        select(row: 0)
        emptyLabel.isHidden = !rows.isEmpty
        updateFooter()
        tableView.displayIfNeeded()
        signposter.endInterval("search", state)
        perfLog.notice("search -> \(self.rows.count) rows in \(String(describing: ContinuousClock.now - start), privacy: .public)")
    }

    /// Everything that matches, best first. A row's score is its text match, plus a
    /// bonus for sources you usually want (apps over clips), plus what it learned from
    /// your past picks for this query. A calculator answer and an exact alias go first.
    private func rankedRows(for text: String, clips: [SearchItem]) -> [Row] {
        let learned = ranking?.bonuses(for: text) ?? [:]
        var scored: [(score: Int, source: Int, order: Int, row: Row)] = []
        func add(_ hits: [(score: Int, item: SearchItem)], source: Int, boost: Int, _ make: (SearchItem) -> Row?) {
            for (i, hit) in hits.enumerated() {
                guard let row = make(hit.item) else { continue }
                let bonus = row.learnKey.flatMap { learned[$0] } ?? 0
                scored.append((hit.score + boost + bonus, source, i, row))
            }
        }
        add(FuzzyMatcher.scoredSearch(text, in: appsProvider(), limit: 20), source: 0, boost: 80) { .app($0) }
        add(FuzzyMatcher.scoredSearch(text, in: projectsProvider(), limit: 20), source: 1, boost: 40) { project($0.id).map(Row.project) }
        let actionItems = actions.enumerated().map { SearchItem(id: $0.offset, title: $0.element.name) }
        add(FuzzyMatcher.scoredSearch(text, in: actionItems, limit: 9), source: 2, boost: -50) { .action(number: $0.id + 1, actions[$0.id]) }
        add(FuzzyMatcher.scoredSearch(text, in: clips, limit: 50), source: 3, boost: 0) { .clip($0) }
        add(FuzzyMatcher.scoredSearch(text, in: historyProvider(), limit: 30), source: 4, boost: 0) { .history($0) }

        var ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.source != $1.source ? $0.source < $1.source : $0.order < $1.order
        }.map(\.row)

        var pinned: [Row] = []
        if let result = Calculator.evaluate(text) { pinned.append(.calc(result, expression: text)) }
        if let match = aliases.match(text), let row = resolve(title: match.target, argument: match.argument) {
            pinned.insert(row, at: 0)
            ranked.removeAll { rowKey($0) == rowKey(row) }
        }
        return pinned + ranked.prefix(40)
    }

    /// The empty box: favourites from config, then what you pick most, then clips.
    private func suggestions() -> [Row] {
        var out = favorites.compactMap { resolve(title: $0, argument: nil) }
        var keys = Set(out.map(rowKey))
        for key in ranking?.top(8) ?? [] where out.count < favorites.count + 3 {
            guard let row = resolve(key: key), keys.insert(rowKey(row)).inserted else { continue }
            out.append(row)
        }
        return out
    }

    /// An alias or favourite target, by name: an action, app or project.
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
        default: return nil
        }
    }

    /// Spotlight answered. Append below the instant rows, keeping the selection.
    func setFileResults(_ hits: [FileHit], for text: String) {
        guard isViewLoaded, case .search = mode, text == searchField.stringValue else { return }
        fileHits = (text, hits)
        let previous = selectedRow.map(rowKey)
        rows = baseRows + hits.map(Row.file)
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        select(row: previous.flatMap { key in rows.firstIndex { rowKey($0) == key } } ?? 0)
    }

    private func iconLoaded(_ path: String) {
        guard isViewLoaded else { return }
        let changed = IndexSet(rows.indices.filter { rows[$0].path == path })
        guard !changed.isEmpty else { return }
        tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
    }

    private func actionRows(filter: String) -> [Row] {
        actions.enumerated().compactMap { i, action in
            guard filter.isEmpty || FuzzyMatcher.score(query: filter, in: action.name) != nil else { return nil }
            return .action(number: i + 1, action)
        }
    }

    private func updateFooter() {
        if let message = notice ?? problem {
            footer.stringValue = message
            footer.textColor = .systemOrange
            return
        }
        footer.textColor = .secondaryLabelColor
        switch mode {
        case .search:
            var hints: [String] = []
            switch selectedRow {
            case .clip?: hints.append("↵ Paste")
            case .history(let item)?: hints.append("↵ Open in \(item.subtitle.components(separatedBy: " · ").first ?? "browser")")
            case .app?, .project?, .file?: hints.append("↵ Open")
            case .calc?: hints.append("↵ Copy answer")
            case nil: break
            default: hints.append("↵ Run")
            }
            if let first = actions.first { hints.append("⌘↵ \(first.name)") }
            hints.append("⌘K Actions")
            if case .clip? = selectedRow { hints += ["⌘C Copy", "⌘⌫ Delete"] }
            if case .history? = selectedRow { hints.append("⌘C Copy URL") }
            if selectedRow?.path != nil { hints.append("⌘C Copy path") }
            footer.stringValue = hints.joined(separator: "    ")
        case .actions:
            footer.stringValue = "↵ Run    1–9 Run    type to filter    esc Back"
        }
    }

    // MARK: - Selection & activation

    private var selectedRow: Row? {
        rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow] : nil
    }

    private func rowKey(_ row: Row) -> String {
        switch row {
        case .clip(let item): "c\(item.id)"
        case .history(let item): "h\(item.title)\(item.subtitle)"
        case .action(let n, _): "a\(n)"
        case .aliasAction(let a, let arg): "a\(a.name)\u{0}\(arg)"
        case .builtin(let b, _): "b\(b.rawValue)"
        case .app(let item): "p\(item.subtitle)"
        case .project(let p): "p\(p.path)"
        case .file(let f): "p\(f.path)"
        case .calc(let r, _): "=\(r.text)"
        }
    }

    private func select(row: Int) {
        guard !rows.isEmpty else { return }
        let r = max(0, min(row, rows.count - 1))
        tableView.selectRowIndexes([r], byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
        updateFooter()
    }

    @objc private func activateSelection() {
        guard let row = selectedRow else { return }
        if case .search = mode, let key = row.learnKey { ranking?.record(query: query, key: key) }
        switch row {
        case .clip(let item): onPaste?(item.id)
        case .history(let item): onOpenHistory?(item.id)
        case .action(_, let action): onRunAction?(action, query)
        case .aliasAction(let action, let argument): onRunAction?(action, argument)
        case .app(let item): onOpenApp?(item.subtitle)
        case .project(let p): onOpenProject?(p.path)
        case .file(let f): onOpenFile?(f.path)
        case .calc(let result, _): onCopyText?(result.text)
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
}

extension LauncherViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { runSearch() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(row: tableView.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)): select(row: tableView.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            if case .actions = mode { enterSearchMode(query: query) } else { onClose?() }
        default: return false
        }
        return true
    }
}

extension LauncherViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell ?? ResultCell()
        let inActions = if case .actions = mode { true } else { false }
        switch rows[row] {
        case .clip(let item):
            cell.configure(icon: "doc.on.clipboard", title: item.title, subtitle: ResultCell.clipSubtitle(item))
        case .history(let item):
            cell.configure(icon: "globe", title: item.title, subtitle: ResultCell.clipSubtitle(item))
        case .action(let n, let action):
            let key = n <= 9 ? (inActions ? "\(n)" : "⌘\(n)") : ""
            cell.configure(icon: "bolt", title: action.name, accessory: tagged(key, title: action.name))
        case .aliasAction(let action, let argument):
            cell.configure(icon: "bolt", title: action.name, detail: "“\(argument)”", accessory: "↵")
        case .builtin(let b, _):
            cell.configure(icon: b.icon, title: b.rawValue, subtitle: b.hint)
        case .app(let item):
            cell.configure(icon: "app", image: IconCache.shared.icon(forPath: item.subtitle), title: item.title,
                           accessory: tagged("Application", title: item.title))
        case .project(let p):
            cell.configure(icon: "folder", image: IconCache.shared.icon(forPath: p.path), title: p.name,
                           detail: ProjectScanner.abbreviate((p.path as NSString).deletingLastPathComponent),
                           accessory: tagged("Project", title: p.name))
        case .file(let f):
            cell.configure(icon: f.isFolder ? "folder" : "doc", image: IconCache.shared.icon(forPath: f.path),
                           title: f.name, detail: f.folder, accessory: f.isFolder ? "Folder" : "File")
        case .calc(let result, let expression):
            cell.configure(icon: "equal.square", title: result.display, detail: expression, accessory: "Calculator")
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }

    /// "Application" → "code · Application" when it has an alias.
    private func tagged(_ label: String, title: String) -> String {
        guard let alias = aliases.alias(for: title) else { return label }
        return label.isEmpty ? alias : "\(alias) · \(label)"
    }
}

/// Reused row view: icon, title, a dimmer detail right after it, and a trailing accessory.
final class ResultCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ResultCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.init(rawValue: 251), for: .horizontal) // truncate the detail first
        title.setContentHuggingPriority(.required, for: .horizontal)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 1
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.setContentHuggingPriority(.required, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [icon, title, detail, subtitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 12),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(icon symbol: String, title text: String, subtitle accessory: String) {
        configure(icon: symbol, title: text, accessory: accessory)
    }

    /// `image` (an app or file icon) wins over the `symbol` placeholder when it's loaded.
    func configure(icon symbol: String, image: NSImage? = nil, title text: String, detail extra: String = "", accessory: String) {
        if let image {
            icon.image = image
            icon.contentTintColor = nil
            icon.symbolConfiguration = nil
        } else {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        }
        // Never lay out megabytes: show the first non-empty line, capped.
        let firstLine = text.prefix(300).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title.stringValue = firstLine.trimmingCharacters(in: .whitespaces)
        detail.stringValue = extra
        subtitle.stringValue = accessory
    }

    static func clipSubtitle(_ item: SearchItem) -> String {
        let age = item.date.map { ageFormatter.localizedString(for: $0, relativeTo: Date()) }
        return [item.subtitle, age].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
