import AppKit
import Carbon.HIToolbox
import EuclidCore

@MainActor
final class LauncherViewController: NSViewController {
    /// Largest size without the preview. The panel shrinks to fit fewer results.
    static let size = NSSize(width: 680, height: 440)
    static let previewWidth: CGFloat = 340

    // Wiring (set by PanelController).
    var onClose: (() -> Void)?
    var onPaste: ((Int) -> Void)?
    var onCopy: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onRunAction: ((Action, _ query: String) -> Void)?
    var onRunTask: ((ProjectTask) -> Void)?
    var onCommand: ((AppCommand) -> Void)?
    var onOpenHistory: ((Int) -> Void)?
    var onCopyHistory: ((Int) -> Void)?
    var onOpenApp: ((String) -> Void)?
    var onOpenProject: ((String) -> Void)?
    var onOpenFile: ((String) -> Void)?
    var onOpenNote: ((String) -> Void)?
    /// Put text on the pasteboard and close (a path, a calculator answer).
    var onCopyText: ((String) -> Void)?
    /// Paste text into the previous app (a snippet).
    var onPasteText: ((String) -> Void)?
    /// ↵ on a plugin's item (open, paste, copy or run it).
    var onPluginItem: ((PluginService.Entry) -> Void)?
    /// A plugin's badge was clicked, by plugin id.
    var onBadgeClick: ((String) -> Void)?
    /// Every plugin `[[key]]`, checked on keys the panel doesn't use itself.
    var modKeys: [(pluginID: String, key: Plugin.Key)] = [] { didSet { if isViewLoaded { updateFooter() } } }
    var onModKey: ((_ pluginID: String, Plugin.Key, ModItem) -> Void)?
    /// You picked a result with ↵ (for `choose` hooks).
    var onChoose: ((ModItem) -> Void)?
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
    /// Items from plugin sources; `id` indexes `pluginEntry`.
    var pluginProvider: () -> [SearchItem] = { [] }
    var pluginEntry: (Int) -> PluginService.Entry? = { _ in nil }
    /// Starts plugin answers for the query; results come back through `setPluginAnswers`.
    var pluginAnswer: ((String) -> Void)?
    /// A plugin's folder, for icons given as relative image paths.
    var pluginDirectory: (String) -> String? = { _ in nil }
    /// `euclid-bar --pick`: the panel is only a view; `esc` on it closes instead of going back to search.
    var standalone = false
    /// Plugin badges on the search bar.
    var badges: [PluginService.BadgeState] = [] { didSet { if isViewLoaded, badges != oldValue { updateBadges() } } }
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
    /// Shown on the rows they open, like aliases ("⌃⌥T · Application").
    var hotkeys: [CommandHotkey] = [] { didSet { if isViewLoaded, hotkeys != oldValue { refreshAfterExternalChange() } } }
    var favorites: [String] = [] { didSet { if isViewLoaded { refreshAfterExternalChange() } } }
    var snippets: [Snippet] = [] {
        didSet {
            snippetItems = snippets.enumerated().map { $0.element.searchItem(id: $0.offset) }
            if isViewLoaded { refreshAfterExternalChange() }
        }
    }
    var theme = Theme() { didSet { if isViewLoaded { applyTheme() } } }
    /// Light or dark when the theme doesn't force one; nil follows the system (renderers pin dark).
    var defaultAppearance: NSAppearance? { didSet { if isViewLoaded { applyTheme() } } }
    private var placeholder = ""

    /// Enabled actions from config, in order.
    var actions: [Action] = [] { didSet { if isViewLoaded { refreshAfterExternalChange() } } }
    /// euclid-bar's own commands ("Check for Updates"), searchable but never suggested.
    var commands: [AppCommand] = [] { didSet { if isViewLoaded, commands != oldValue { refreshAfterExternalChange() } } }
    /// Persistent message (e.g. config problem) shown in the footer instead of hints.
    var problem: String? { didSet { if isViewLoaded { updateFooter() } } }
    /// "Unregistered", after the search speed.
    var licenceNote = "" { didSet { if isViewLoaded, licenceNote != oldValue { updateFooter() } } }
    /// One-off message (e.g. last action failed). Cleared when the panel hides.
    var notice: String? { didSet { if isViewLoaded { updateFooter() } } }
    /// The empty bar's footer tip (PanelController rotates it per open).
    var tip: Tip? { didSet { if isViewLoaded, tip != oldValue { updateFooter() } } }
    /// You used something a tip shows ("filter", "preview"…), so it can retire.
    var onFeatureUsed: ((String) -> Void)?
    /// `[search] scopes`: typed prefixes that narrow the search ("c" → "clipboard").
    var scopePrefixes: [String: String] = [:]
    /// Note search is on (`[obsidian] vault`), so Notes is a source.
    var hasNotes = false
    /// Spotlight file search is on.
    var hasFiles = true

    private enum Mode: Equatable {
        case search
        /// ⌘K list. Remembers the query (actions run on it) and the clip that was selected.
        case actions(query: String, clipID: Int?)
        /// A plugin's view (`views.last`): a list, a grid or text to read.
        case view
    }
    private var mode = Mode.search
    /// ⇥ narrowed the search to one source; nil = everything.
    private var scope: SearchScope?
    /// The scope and text the last search actually ran with (a typed `[search] scopes` prefix sets both).
    private var activeScope: SearchScope?
    private var searchedText = ""

    /// Views a plugin opened, newest last; `esc` goes back one.
    private struct ViewState {
        var view: PluginView
        let pluginID: String
        let pluginName: String
        /// What the search box had under it, to put back.
        let under: String
        /// Tells a reload's reply apart from one for a view that has since closed.
        let id = UUID()
        /// An item's ⌘K actions: running one goes back to the view it's for.
        var isActions = false
    }
    private var views: [ViewState] = []
    /// A live view's next `refresh_seconds` reload.
    private var refreshTimer: Timer?
    /// The view whose `reload` (or `search`) is running, so they never pile up.
    private var reloading: UUID?
    /// Something changed while one was running: run it again when it's back.
    private var reloadAgain = false
    /// Typing in a view with `search`: wait for a pause before asking the script.
    private var searchTimer: Timer?
    /// Run a view's `reload`, or its `search` with what you typed (`query`); the reply comes back
    /// through `viewReloaded`.
    var onReloadView: ((_ command: String, _ pluginID: String, _ viewID: UUID, _ query: String?) -> Void)?
    private var layout: PluginView.Layout? { mode == .view ? views.last?.view.layout : nil }

    /// An item's fields, shown in the search row while you fill them in.
    private var argumentEntry: PluginService.Entry?
    private var argumentFields: [NSTextField] = []
    private var argumentSavedText = ""
    /// The project ⌘K was pressed on, and what it can run.
    private var projectTasks: (name: String, tasks: [ProjectTask])?

    private let itemsProvider: () -> [SearchItem]
    private var snippetItems: [SearchItem] = []
    private var rows: [Row] = []
    /// Rows from the instant sources; async hits (notes, files) are appended below them.
    private var baseRows: [Row] = []
    /// The instant rows are only the “Use … with” fallback, so an answer can go above them.
    private var baseIsFallback = false
    private var fileHits: (query: String, hits: [FileHit]) = ("", [])
    private var contentHits: (query: String, hits: [ContentHit]) = ("", [])
    private var pluginAnswers: (query: String, entries: [PluginService.Entry]) = ("", [])
    private var keyMonitor: Any?
    private var previewOpen = false
    /// You closed the preview: ↑/↓ leaves it closed until the panel opens again.
    private var previewDismissed = false
    /// Holding ↑/↓: the preview waits for where you stop instead of loading every row on the way.
    private var previewTimer: Timer?
    /// "12,431 items · 0.6 ms", refreshed on every search.
    private var lastStats = ""

    private let background = NSView()
    private let glowLine = NSView()
    private let footerBar = NSView()
    private let scopeChip = ScopeChipView()
    private var fieldLeading: NSLayoutConstraint!
    private var fieldAfterChip: NSLayoutConstraint!
    /// Left side of the footer: ⇥ Filter, ⌘/ Shortcuts, and the tip.
    private let leadHints = HintBar()
    private let tipLabel = NSTextField(labelWithString: "")
    private lazy var leadStack = NSStackView(views: [leadHints, tipLabel])
    private var effectView: NSView?
    private var installedGlass: Bool?
    private let content = NSView()
    private let searchField = NSTextField()
    private let modeLabel = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private let argumentStack = NSStackView()
    private let grid = GridView()
    private let gridScroll = NSScrollView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let hints = HintBar()
    private let stats = NSTextField(labelWithString: "")
    private let preview = PreviewView()
    private let previewDivider = NSBox()
    private var listTrailing: NSLayoutConstraint!
    /// A detail view: the list gives its width to the text.
    private var listCollapsed: NSLayoutConstraint!

    /// Space above and below the list: search field and footer.
    private static let chrome: CGFloat = 60 + 34

    init(items: @escaping () -> [SearchItem]) {
        self.itemsProvider = items
        super.init(nibName: nil, bundle: nil)
        IconCache.shared.onLoad = { [weak self] path in self?.iconLoaded(path) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = PanelRootView(frame: NSRect(origin: .zero, size: Self.size))
        root.onAppearanceChange = { [weak self] in self?.applyLayerColors() }
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        view = root
        background.frame = root.bounds
        background.autoresizingMask = [.width, .height]
        root.addSubview(background)
        // A 1 pt light along the top edge, inside the corners: the panel reads as a lit surface.
        glowLine.wantsLayer = true
        glowLine.frame = NSRect(x: 18, y: root.bounds.height - 1, width: root.bounds.width - 36, height: 1)
        glowLine.autoresizingMask = [.width, .minYMargin]
        root.addSubview(glowLine)
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
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 6
        badgeStack.setHuggingPriority(.required, for: .horizontal)
        badgeStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        argumentStack.orientation = .horizontal
        argumentStack.spacing = 6
        argumentStack.setHuggingPriority(.required, for: .horizontal)
        argumentStack.isHidden = true

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
        scrollView.scrollerStyle = .overlay // only while scrolling, never over the selection
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        scrollView.automaticallyAdjustsContentInsets = false

        grid.autoresizingMask = [.width]
        grid.image = { [weak self] e in PluginIcon.image(e.item.icon, directory: self?.pluginDirectory(e.pluginID)) }
        grid.onSelect = { [weak self] i in self?.select(row: i) }
        grid.onActivate = { [weak self] i in
            self?.select(row: i)
            self?.activateSelection()
        }
        gridScroll.documentView = grid
        gridScroll.drawsBackground = false
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.scrollerStyle = .overlay
        gridScroll.isHidden = true

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        // Areas are told apart by surfaces (the darker footer strip), not lines.
        divider.isHidden = true
        footerDivider.isHidden = true
        footerBar.wantsLayer = true
        tipLabel.lineBreakMode = .byTruncatingTail
        tipLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leadStack.spacing = 12
        leadStack.alignment = .centerY
        leadStack.setHuggingPriority(.init(750), for: .horizontal)
        leadStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // The right-hand hints hug, so they sit against the speed readout.
        hints.setHuggingPriority(.init(750), for: .horizontal)
        scopeChip.isHidden = true
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
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        previewDivider.boxType = .separator
        // A separator's intrinsic height is 1pt; stood on end it must not pull the
        // window down to that (it hugs harder than the window keeps its size).
        previewDivider.setContentHuggingPriority(.defaultLow, for: .vertical)
        previewDivider.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.isHidden = true
        previewDivider.isHidden = true

        for v in [footerBar, scopeChip, searchField, argumentStack, badgeStack, modeLabel, divider, scrollView, gridScroll, emptyLabel,
                  footerDivider, footer, leadStack, hints, stats, preview, previewDivider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        listTrailing = scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        listCollapsed = scrollView.widthAnchor.constraint(equalToConstant: 0)
        fieldLeading = searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.gutter - 2)
        fieldAfterChip = searchField.leadingAnchor.constraint(equalTo: scopeChip.trailingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            fieldLeading,
            scopeChip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.gutter - 2),
            scopeChip.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            footerBar.topAnchor.constraint(equalTo: footerDivider.topAnchor),
            footerBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            searchField.trailingAnchor.constraint(equalTo: argumentStack.leadingAnchor, constant: -8),
            argumentStack.trailingAnchor.constraint(equalTo: badgeStack.leadingAnchor, constant: -8),
            argumentStack.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            badgeStack.trailingAnchor.constraint(equalTo: modeLabel.leadingAnchor, constant: -8),
            badgeStack.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            modeLabel.firstBaselineAnchor.constraint(equalTo: searchField.firstBaselineAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            modeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: 59),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            // Below the window's own size (500), so the panel can animate its width.
            scrollView.widthAnchor.constraint(equalToConstant: Self.size.width).withPriority(.init(490)),
            listTrailing,
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            gridScroll.topAnchor.constraint(equalTo: scrollView.topAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            previewDivider.topAnchor.constraint(equalTo: divider.bottomAnchor),
            previewDivider.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            previewDivider.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            previewDivider.widthAnchor.constraint(equalToConstant: 1),
            // An inset card on its own surface, not a slab.
            preview.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            preview.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -8),
            preview.leadingAnchor.constraint(equalTo: previewDivider.trailingAnchor, constant: 2),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

            footerDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -33),

            leadStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            leadStack.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -16.5),
            hints.leadingAnchor.constraint(greaterThanOrEqualTo: leadStack.trailingAnchor, constant: 16),
            hints.centerYAnchor.constraint(equalTo: leadStack.centerYAnchor),
            hints.trailingAnchor.constraint(equalTo: stats.leadingAnchor, constant: -16).withPriority(.init(999)),
            hints.trailingAnchor.constraint(lessThanOrEqualTo: stats.leadingAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.centerYAnchor.constraint(equalTo: hints.centerYAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: stats.leadingAnchor, constant: -12),
            stats.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stats.centerYAnchor.constraint(equalTo: hints.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
        ])
        applyTheme()
        updateBadges()
        installKeyMonitor()
        enterSearchMode(query: "")
    }

    /// Background (Liquid Glass or blur), colours, sizes and fonts from `[appearance]`.
    private func applyTheme() {
        searchField.font = .systemFont(ofSize: theme.querySize, weight: .regular)
        if installedGlass != theme.glass { installBackground(glass: theme.glass) }
        view.appearance = theme.appearance ?? defaultAppearance
        setPlaceholder(placeholder)
        content.wantsLayer = true
        applyLayerColors()
        searchField.textColor = theme.text
        modeLabel.textColor = theme.subtext
        footer.textColor = theme.warning
        stats.textColor = theme.muted
        emptyLabel.textColor = theme.muted
        hints.theme = theme
        leadHints.theme = theme
        if let scope { scopeChip.show(scope, theme: theme) }
        preview.theme = theme
        preview.applyCard()
        grid.theme = theme
        updatePreview()
        tableView.reloadData()
        if !rows.isEmpty { select(row: max(tableView.selectedRow, 0)) }
        updateFooter()
        notifySize()
    }

    /// Layer colours (dynamic ones resolve for light or dark): the border, the accent wash, the footer strip, the top light.
    private func applyLayerColors() {
        view.resolving {
            view.layer?.borderColor = theme.border.cgColor
            content.layer?.backgroundColor = (theme.background ?? theme.surfaceTint)?.cgColor
            footerBar.layer?.backgroundColor = theme.footerFill.cgColor
            glowLine.layer?.backgroundColor = theme.glow.cgColor
        }
        preview.applyCard()
    }

    /// In the theme's faintest colour; the system look keeps the stock placeholder.
    private func setPlaceholder(_ text: String) {
        placeholder = text
        searchField.placeholderAttributedString = nil
        searchField.placeholderString = text
        guard theme.background != nil else { return }
        searchField.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .foregroundColor: theme.muted, .font: NSFont.systemFont(ofSize: theme.querySize, weight: .regular),
        ])
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

    // MARK: - Badges

    /// One small button per plugin badge, left of the mode label.
    private func updateBadges() {
        badgeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for b in badges {
            let button = NSButton(title: b.text, target: self, action: #selector(badgeClicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(b.pluginID)
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            if let icon = b.icon, let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
                button.image = image
                button.imagePosition = .imageLeading
            }
            button.toolTip = b.hasClick ? "Click to open" : nil
            button.refusesFirstResponder = true // typing stays in the search field
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            badgeStack.addArrangedSubview(button)
        }
        badgeStack.isHidden = badges.isEmpty
    }

    @objc private func badgeClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, badges.first(where: { $0.pluginID == id })?.hasClick == true else { return }
        onBadgeClick?(id)
    }

    // MARK: - Lifecycle

    /// Called right before the panel is shown: fresh search, focused field.
    func prepareForShow() {
        endArguments()
        setPreview(open: false)
        previewDismissed = false
        views = []
        scope = nil
        enterSearchMode(query: "")
        view.window?.makeFirstResponder(searchField)
    }

    func didHide() {
        stopRefresh()
        notice = nil
        endArguments()
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

    func demoSetQuery(_ text: String) {
        searchField.stringValue = text
        runSearch()
        searchField.currentEditor()?.moveToEndOfDocument(nil)
    }

    /// An `open` hook's `{"query":…}`: start the search with it, unless you already typed.
    func suggestQuery(_ text: String) {
        guard case .search = mode, searchField.stringValue.isEmpty else { return }
        enterSearchMode(query: text)
    }
    func demoToggleActions() { if case .actions = mode { enterSearchMode(query: query) } else { enterActionsMode() } }
    /// Select the nth result, not counting section headers.
    func demoSelect(row: Int) {
        let selectable = rows.indices.filter { !rows[$0].isHeader }
        if selectable.indices.contains(row) { select(row: selectable[row]) }
    }
    var demoRowCount: Int { rows.filter { !$0.isHeader }.count }
    func demoMove(by step: Int) { move(by: step) }

    func demoTogglePreview() { setPreview(open: !previewOpen) }
    /// ↵ on the selected result, as if pressed (renders the argument fields).
    func demoActivate() { activateSelection() }
    /// ⇥ in the search box.
    func demoTab() { tabScope(backwards: false) }
    /// ⌘/.
    func demoShowShortcuts() { showCheatSheet() }

    // MARK: - Modes

    private func enterSearchMode(query: String) {
        stopRefresh()
        mode = .search
        views = []
        applyLayout()
        searchField.stringValue = query
        setPlaceholder("Search everything")
        modeLabel.stringValue = ""
        updateScopeChip()
        runSearch()
        searchField.currentEditor()?.moveToEndOfDocument(nil)
    }

    private func enterActionsMode() {
        let clipID: Int? = if case .clip(let item)? = selectedRow { item.id } else { nil }
        if case .project(let p)? = selectedRow {
            let tasks = ProjectTasks.scan(p.path)
            projectTasks = tasks.isEmpty ? nil : (p.name, tasks)
        } else {
            projectTasks = nil
        }
        let query = searchField.stringValue
        stopRefresh()
        mode = .actions(query: query, clipID: clipID)
        views = []
        applyLayout()
        updateScopeChip()
        onFeatureUsed?("actions")
        searchField.stringValue = ""
        setPlaceholder("Filter actions…")
        modeLabel.stringValue = query.isEmpty ? "Actions" : "Actions · “\(query)”"
        runSearch()
    }

    /// The text actions run on: the typed query (remembered while in ⌘K).
    var query: String {
        if case .actions(let q, _) = mode { return q }
        return searchField.stringValue
    }

    // MARK: - Scopes (⇥)

    /// Sources ⇥ can narrow to, in order: the built-in ones that have anything, then each plugin with items.
    private var availableScopes: [SearchScope] {
        var out: [SearchScope] = SearchScope.builtIn.filter { s in
            switch s {
            case .apps: true
            case .files: hasFiles
            case .clipboard: true
            case .history: !historyProvider().isEmpty
            case .projects: !projectsProvider().isEmpty
            case .snippets: !snippets.isEmpty
            case .notes: hasNotes
            case .actions: !actions.isEmpty
            case .plugin: false
            }
        }
        var seen = Set<String>()
        for e in pluginProvider().compactMap({ pluginEntry($0.id) }) where seen.insert(e.pluginID).inserted {
            out.append(.plugin(id: e.pluginID, name: e.pluginName))
        }
        return out
    }

    /// Narrow to `newScope` (nil = everything) and search `query` in it.
    private func setScope(_ newScope: SearchScope?, query: String) {
        scope = newScope
        if newScope != nil { onFeatureUsed?("filter") }
        searchField.stringValue = query
        updateScopeChip()
        runSearch()
        searchField.currentEditor()?.moveToEndOfDocument(nil)
    }

    private func updateScopeChip() {
        let shown = mode == .search ? scope : nil
        if let shown { scopeChip.show(shown, theme: theme) }
        scopeChip.isHidden = shown == nil
        fieldLeading.isActive = shown == nil
        fieldAfterChip.isActive = shown != nil
    }

    /// ⇥ / ⇧⇥ in the search box: a typed source name ("clip⇥") jumps to it, otherwise the next source.
    private func tabScope(backwards: Bool) {
        let scopes = availableScopes
        let typed = searchField.stringValue
        if scope == nil, !backwards, let named = SearchScope.named(typed, among: scopes) {
            setScope(named, query: "")
        } else {
            setScope(SearchScope.next(after: scope, in: scopes, backwards: backwards), query: typed)
        }
    }

    /// ⌘/: every key, source, prefix and keyword, as a view (`esc` comes back).
    private func showCheatSheet() {
        onFeatureUsed?("shortcuts")
        let text = CheatSheet.text(
            scopes: availableScopes, prefixes: scopePrefixes, actions: actions.map(\.name),
            aliases: aliases.targets.sorted { $0.key < $1.key }.map { (alias: $0.key, target: $0.value) },
            snippets: snippets.compactMap { s in s.keyword.map { (keyword: $0, name: s.name) } },
            pluginKeys: modKeys.map { (key: $0.key.key.symbols, name: $0.key.name) })
        present(PluginView(layout: .detail, title: "Shortcuts", text: text, code: true), pluginID: "euclid", pluginName: "Euclid")
    }

    // MARK: - Plugin views

    /// A script printed a view: show it on top of whatever is open (`esc` comes back here).
    func present(_ view: PluginView, pluginID: String, pluginName: String, isActions: Bool = false) {
        endArguments()
        setPreview(open: false)
        let under = mode == .view ? searchField.stringValue : query
        if case .actions = mode { mode = .search }
        views.append(ViewState(view: view, pluginID: pluginID, pluginName: pluginName, under: under, isActions: isActions))
        showTopView(text: "")
    }

    private func showTopView(text: String) {
        guard let top = views.last else { return }
        mode = .view
        applyLayout()
        updateScopeChip()
        searchField.stringValue = text
        let fallback = top.view.layout == .detail ? "" : "Filter \(top.view.title.isEmpty ? top.pluginName : top.view.title)…"
        setPlaceholder(top.view.placeholder ?? fallback)
        modeLabel.stringValue = top.view.title.isEmpty ? top.pluginName : top.view.title
        runSearch()
        searchField.currentEditor()?.moveToEndOfDocument(nil)
        scheduleRefresh()
    }

    /// `esc` in a view: back to the one under it, or to the search you came from.
    private func popView() {
        guard let top = views.popLast() else { return }
        stopRefresh()
        if reloading == top.id { reloading = nil }
        if views.isEmpty {
            if standalone { onClose?(); return }
            enterSearchMode(query: top.under)
        } else {
            showTopView(text: top.under)
            reloadTopView() // it may be out of date after what you did in the one you left
        }
    }

    // MARK: - Live views (`reload`, `refresh_seconds`)

    /// Run the open view's `reload` now, if it has one: after a `run` in it changed something,
    /// when you come back to it, and on its `refresh_seconds` timer.
    func reloadTopView() {
        guard mode == .view, argumentEntry == nil, let top = views.last,
              let command = top.view.search ?? top.view.reload else { return }
        guard reloading == nil else { reloadAgain = true; return }
        refreshTimer?.invalidate()
        searchTimer?.invalidate()
        reloading = top.id
        onReloadView?(command, top.pluginID, top.id, top.view.search == nil ? nil : searchField.stringValue)
    }

    /// ⌘K on a plugin item with `actions`: they open as a list on top; ↵ runs one and comes back.
    private func presentActions(for e: PluginService.Entry) {
        guard let actions = e.item.actions, !actions.isEmpty else { return }
        present(PluginView(layout: .list, title: e.item.title, placeholder: "Actions for \(e.item.title)…", items: actions),
                pluginID: e.pluginID, pluginName: e.pluginName, isActions: true)
    }

    /// Leave an actions list before running one of its actions, so a live view under it reloads.
    private func leaveActions() {
        if mode == .view, views.last?.isActions == true { popView() }
    }

    /// What `reload` printed for view `id` (nil: it failed or printed no view). The rows change
    /// in place: the filter text stays and the selection follows its item.
    func viewReloaded(_ id: UUID, with fresh: PluginView?, query: String?) {
        if reloading == id { reloading = nil }
        defer {
            if reloadAgain, reloading == nil { reloadAgain = false; reloadTopView() }
        }
        guard let i = views.firstIndex(where: { $0.id == id }) else { return }
        let isTop = i == views.count - 1 && mode == .view
        // Rows for what you typed before the latest keystroke: ask again instead.
        if let query, isTop, query != searchField.stringValue { reloadAgain = true; return }
        if let fresh {
            if query != nil {
                views[i].view.items = fresh.items // a search's rows; the view stays as it was
            } else {
                var fresh = fresh
                if fresh.reload == nil { (fresh.reload, fresh.refreshSeconds) = (views[i].view.reload, views[i].view.refreshSeconds) }
                if fresh.search == nil { fresh.search = views[i].view.search }
                views[i].view = fresh
            }
            if isTop { refreshTopView() }
        }
        if i == views.count - 1 { scheduleRefresh() }
    }

    private func refreshTopView() {
        guard let top = views.last else { return }
        let previous = selectedRow.map(\.key)
        modeLabel.stringValue = top.view.title.isEmpty ? top.pluginName : top.view.title
        if top.view.layout == .detail {
            applyLayout()
            return
        }
        runSearch()
        if let previous, let row = rows.firstIndex(where: { $0.key == previous }) { select(row: row) }
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard mode == .view, let seconds = views.last?.view.refreshSeconds else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadTopView() }
        }
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        searchTimer?.invalidate()
        searchTimer = nil
    }

    private func scheduleSearch() {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadTopView() }
        }
    }

    /// The list, the grid or the detail text, for the mode.
    private func applyLayout() {
        let layout = self.layout
        scrollView.isHidden = layout == .grid || layout == .detail
        gridScroll.isHidden = layout != .grid
        if layout == .detail {
            previewOpen = false
            listTrailing.isActive = false
            listCollapsed.isActive = true
            preview.isHidden = false
            previewDivider.isHidden = true
            if let top = views.last {
                preview.show(.text(title: top.view.title, facts: [], body: top.view.text, code: top.view.code))
            }
        } else {
            listCollapsed.isActive = false
            if !previewOpen {
                listTrailing.isActive = true
                preview.isHidden = true
                previewDivider.isHidden = true
                preview.clear()
            }
        }
        if layout == .grid, let top = views.last { grid.columns = top.view.columns }
    }

    // MARK: - Arguments

    /// ↵ on an item with `arguments`: show its fields in the search row; ↵ again runs it with them.
    private func beginArguments(_ entry: PluginService.Entry) {
        endArguments()
        argumentEntry = entry
        argumentSavedText = searchField.stringValue
        searchField.stringValue = entry.item.title
        searchField.isEditable = false
        for arg in entry.item.fields {
            let field: NSTextField
            switch arg.type {
            case .password: field = NSSecureTextField()
            case .dropdown:
                let combo = NSComboBox()
                combo.addItems(withObjectValues: arg.data.map(\.title))
                combo.completes = true
                combo.numberOfVisibleItems = 10
                combo.delegate = self
                field = combo
            case .text: field = NSTextField()
            }
            let placeholder = arg.placeholder.isEmpty ? (arg.optional ? "optional" : "") : arg.placeholder
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.muted,
            ])
            field.font = .systemFont(ofSize: 13)
            field.textColor = theme.text
            field.delegate = self
            argumentStack.addArrangedSubview(Self.fieldPlate(field, width: arg.type == .dropdown ? 150 : 140, theme: theme))
            argumentFields.append(field)
        }
        for (i, f) in argumentFields.enumerated() { f.nextKeyView = argumentFields[(i + 1) % argumentFields.count] }
        argumentStack.isHidden = false
        view.window?.makeFirstResponder(argumentFields.first)
        updateFooter()
    }

    /// A flat field in the panel's own colours (a chip-fill plate with a hairline edge), not the stock
    /// white bezel. Dropdowns keep their arrow button, on the same plate.
    private static func fieldPlate(_ field: NSTextField, width: CGFloat, theme: Theme) -> NSView {
        let plate = NSView()
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 6
        plate.layer?.borderWidth = 1
        plate.resolving {
            plate.layer?.backgroundColor = theme.chipFill.cgColor
            plate.layer?.borderColor = theme.subtext.withAlphaComponent(0.28).cgColor
        }
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        if let combo = field as? NSComboBox { combo.isButtonBordered = false }
        field.translatesAutoresizingMaskIntoConstraints = false
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(field)
        NSLayoutConstraint.activate([
            plate.widthAnchor.constraint(equalToConstant: width),
            plate.heightAnchor.constraint(equalToConstant: 26),
            field.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: field is NSComboBox ? -2 : -8),
            field.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
        return plate
    }

    private func endArguments() {
        guard argumentEntry != nil else { return }
        argumentEntry = nil
        argumentFields = []
        argumentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        argumentStack.isHidden = true
        searchField.isEditable = true
        searchField.stringValue = argumentSavedText
        view.window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.moveToEndOfDocument(nil)
        updateFooter()
    }

    /// ↵ in the fields: run with them, or point at the first one that can't be used yet.
    private func submitArguments() {
        guard var entry = argumentEntry else { return }
        var values: [String] = []
        for (arg, field) in zip(entry.item.fields, argumentFields) {
            guard let v = arg.value(for: field.stringValue) else {
                NSSound.beep()
                view.window?.makeFirstResponder(field)
                return
            }
            values.append(v)
        }
        entry.arguments = values
        endArguments()
        if mode == .search, let key = Row.plugin(entry).learnKey { ranking?.record(query: query, key: key) }
        leaveActions()
        onPluginItem?(entry)
    }

    // MARK: - Search

    private func runSearch() {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("search")
        var text = searchField.stringValue
        var searched = 0

        switch mode {
        case .search:
            let all = itemsProvider()
            // A typed `[search] scopes` prefix ("c kube") narrows like ⇥ does.
            activeScope = scope
            if scope == nil, !scopePrefixes.isEmpty, text.contains(" "),
               let hit = SearchScope.prefixed(text, prefixes: scopePrefixes, among: availableScopes) {
                activeScope = hit.0
                text = hit.1
            }
            searchedText = text
            if let only = activeScope {
                let ranked = text.isEmpty ? listing(only, clips: all) : rankedRows(for: text, clips: all, only: only)
                searched = ranked.searched
                baseRows = ranked.rows // one source: the chip says which, so no section header
                baseIsFallback = false
            } else if text.isEmpty {
                let clips = FuzzyMatcher.search(text, in: all).map(Row.clip)
                // The map of sources first: it shows what Euclid searches, and goes away on the first keystroke.
                baseRows = [Row.scopeBar] + suggestions() + (clips.isEmpty ? [] : [.header("Clipboard")] + clips)
                baseIsFallback = false
                searched = all.count
            } else {
                let ranked = rankedRows(for: text, clips: all)
                searched = ranked.searched
                baseIsFallback = ranked.rows.isEmpty && !actions.isEmpty
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
            if pluginAnswers.query != text { pluginAnswers = (text, []) }
            fileSearch?(wants(.files) ? text : "")
            contentSearch?(wants(.notes) ? text : "")
            pluginAnswer?(activeScope == nil ? text : "")
            rows = withAsyncRows(baseRows)
            if let only = activeScope {
                emptyLabel.stringValue = text.isEmpty && (only == .files || only == .notes)
                    ? "Type to search \(only.title.lowercased())."
                    : "No matches in \(only.title). esc searches everything."
            } else {
                emptyLabel.stringValue = all.isEmpty && text.isEmpty ? "Copy something — it will show up here." : "No matches"
            }

        case .actions(_, let clipID):
            fileSearch?("")
            contentSearch?("")
            pluginAnswer?("")
            rows = actionRows(filter: text)
            if let project = projectTasks {
                let matching = project.tasks.filter { text.isEmpty || FuzzyMatcher.score(query: text, in: $0.command) != nil }
                    .map { Row.task($0, project: project.name) }
                if !matching.isEmpty { rows = [.header("Tasks · \(project.name)")] + matching + (rows.isEmpty ? [] : [.header("Actions")] + rows) }
                searched += project.tasks.count
            }
            if let clipID {
                rows += Row.Builtin.allCases
                    .filter { text.isEmpty || FuzzyMatcher.score(query: text, in: $0.rawValue) != nil }
                    .map { .builtin($0, clipID: clipID) }
            }
            searched += actions.count
            emptyLabel.stringValue = actions.isEmpty && clipID == nil && projectTasks == nil
                ? "No actions yet — add [[action]] blocks to config.toml" : "No matching actions"

        case .view:
            fileSearch?("")
            contentSearch?("")
            pluginAnswer?("")
            rows = []
            if let top = views.last, top.view.layout != .detail {
                let items = top.view.items
                searched = items.count
                let entries = items.enumerated().map {
                    PluginService.Entry(pluginID: top.pluginID, pluginName: top.pluginName, item: $0.element, index: $0.offset)
                }
                var shown = entries
                if !text.isEmpty, top.view.search == nil { // with `search`, the script already picked them
                    let found = FuzzyMatcher.scoredSearch(text, in: items.enumerated().map { $0.element.searchItem(id: $0.offset) },
                                                          limit: PluginOutput.maxItems)
                    shown = found.map { entries[$0.item.id] }
                }
                rows = shown.map { Row.plugin($0) }
                if top.view.layout == .grid {
                    grid.entries = shown
                    grid.selected = 0
                    grid.scroll(.zero)
                }
                emptyLabel.stringValue = items.isEmpty ? "Nothing here" : "No matches"
            }
        }

        tableView.reloadData()
        select(row: 0)
        emptyLabel.isHidden = !rows.isEmpty || layout == .detail
        let elapsed = ContinuousClock.now - start
        lastStats = layout == .detail ? "" : Self.stats(items: searched, elapsed: elapsed)
        if mode == .search, let only = activeScope { lastStats = "\(only.title) · \(lastStats)" }
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
        return "\(items.formatted()) \(items == 1 ? "item" : "items") · \(time)"
    }

    /// Async hits go last, so they never push the instant rows around. The one exception:
    /// when nothing matched, plugin answers go above the “Use … with” fallback, so ↵ takes the answer.
    private func withAsyncRows(_ base: [Row]) -> [Row] {
        // Answers first: they reply to exactly what was typed.
        var answers: [Row] = [], answered: [String] = [], byPlugin: [String: [Row]] = [:]
        for e in pluginAnswers.entries {
            if byPlugin[e.pluginName] == nil { answered.append(e.pluginName) }
            byPlugin[e.pluginName, default: []].append(.plugin(e))
        }
        for name in answered { answers += [.header(name)] + byPlugin[name]! }
        if activeScope != nil { answers = [] }
        var out = baseIsFallback ? answers + base : base + answers
        // In one source, no section header: the chip already says which.
        let header = activeScope == nil
        if wants(.notes), !contentHits.hits.isEmpty { out += (header ? [.header("Notes")] : []) + contentHits.hits.map(Row.content) }
        if wants(.files), !fileHits.hits.isEmpty { out += (header ? [.header("Files")] : []) + fileHits.hits.map(Row.file) }
        return out
    }

    /// The search covers `source`: everything, or exactly it.
    private func wants(_ source: SearchScope) -> Bool { activeScope == nil || activeScope == source }

    /// A source with nothing typed yet: all of it, most useful first.
    private func listing(_ only: SearchScope, clips: [SearchItem]) -> (rows: [Row], searched: Int) {
        switch only {
        case .apps:
            let apps = appsProvider()
            return (apps.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.map(Row.app), apps.count)
        case .clipboard: return (FuzzyMatcher.search("", in: clips).map(Row.clip), clips.count)
        case .history:
            let h = historyProvider()
            return (h.prefix(50).map(Row.history), h.count)
        case .projects:
            let p = projectsProvider()
            return (p.compactMap { project($0.id) }.map(Row.project), p.count)
        case .snippets: return (snippetItems.indices.map { .snippet(snippetItems[$0], snippets[$0]) }, snippets.count)
        case .actions: return (actionRows(filter: ""), actions.count)
        case .plugin(let id, _):
            let entries = pluginProvider().compactMap { pluginEntry($0.id) }.filter { $0.pluginID == id }
            return (entries.map(Row.plugin), entries.count)
        case .files, .notes: return ([], 0) // need words to search
        }
    }

    /// Everything that matches, best first. A row's score is its text match, plus a
    /// bonus for sources you usually want (apps over clips), plus what it learned from
    /// your past picks for this query. Answers (calculator, conversions) and an exact
    /// alias or snippet keyword go first.
    private func rankedRows(for text: String, clips: [SearchItem], only: SearchScope? = nil) -> (rows: [Row], searched: Int) {
        let learned = ranking?.bonuses(for: text) ?? [:]
        var scored: [(score: Int, source: Int, order: Int, row: Row)] = []
        var searched = 0
        func add(_ items: @autoclosure () -> [SearchItem], limit: Int, source: Int, boost: Int, scope: SearchScope?,
                 _ make: (SearchItem) -> Row?) {
            if let only, only != scope { return }
            let items = items()
            searched += items.count
            for (i, hit) in FuzzyMatcher.scoredSearch(text, in: items, limit: limit).enumerated() {
                guard let row = make(hit.item) else { continue }
                let bonus = row.learnKey.flatMap { learned[$0] } ?? 0
                scored.append((hit.score + boost + bonus, source, i, row))
            }
        }
        add(appsProvider(), limit: 20, source: 0, boost: 80, scope: .apps) { .app($0) }
        add(projectsProvider(), limit: 20, source: 1, boost: 40, scope: .projects) { project($0.id).map(Row.project) }
        if case .plugin(let id, _)? = only {
            // One plugin's items only: filter before matching, so its limit isn't spent on other plugins.
            let mine = pluginProvider().filter { pluginEntry($0.id)?.pluginID == id }
            add(mine, limit: 50, source: 9, boost: 30, scope: only) { pluginEntry($0.id).map(Row.plugin) }
        } else {
            add(pluginProvider(), limit: 15, source: 9, boost: 30, scope: nil) { pluginEntry($0.id).map(Row.plugin) }
        }
        add(snippetItems, limit: 9, source: 3, boost: 20, scope: .snippets) { item in
            snippets.indices.contains(item.id) ? .snippet(item, snippets[item.id]) : nil
        }
        add(actions.enumerated().map { SearchItem(id: $0.offset, title: $0.element.name) }, limit: 9, source: 4, boost: -50,
            scope: .actions) { .action(number: $0.id + 1, actions[$0.id]) }
        add(clips, limit: 50, source: 5, boost: 0, scope: .clipboard) { .clip($0) }
        add(commands.enumerated().map { SearchItem(id: $0.offset, title: $0.element.title) }, limit: 5, source: 7, boost: -50,
            scope: nil) { .command(commands[$0.id]) }
        add(historyProvider(), limit: 30, source: 6, boost: 0, scope: .history) { .history($0) }

        var ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.source != $1.source ? $0.source < $1.source : $0.order < $1.order
        }.map(\.row)

        var pinned: [Row] = []
        var top: [Row] = []
        if only == nil { // answers and aliases belong to the whole search
            if let result = Calculator.evaluate(text) { pinned.append(.calc(result, expression: text)) }
            pinned += DevTransforms.evaluate(text).map(Row.transform)
            if let match = aliases.match(text), let row = resolve(title: match.target, argument: match.argument) { top.append(row) }
        }
        if only == nil || only == .snippets, let i = snippets.firstIndex(where: { $0.keyword?.lowercased() == text.lowercased() }) {
            top.append(.snippet(snippetItems[i], snippets[i]))
        }
        let topKeys = Set(top.map(\.key))
        ranked.removeAll { topKeys.contains($0.key) }
        return (top + pinned + Array(ranked.prefix(40)), searched)
    }

    /// The empty box: favourites from config, then what you pick most, then plugin suggestions
    /// (PRs waiting on your review, issues assigned to you).
    private func suggestions() -> [Row] {
        var picks = favorites.compactMap { resolve(title: $0, argument: nil) }
        var keys = Set(picks.map(\.key))
        for key in ranking?.top(8) ?? [] where picks.count < favorites.count + 3 {
            guard let row = resolve(key: key), keys.insert(row.key).inserted else { continue }
            picks.append(row)
        }
        var out: [Row] = picks.isEmpty ? [] : [.header("Suggestions")] + picks
        // Plugin items marked "suggest": up to 3 per plugin, under its name.
        var suggested: [String] = [], byPlugin: [String: [Row]] = [:]
        for e in pluginProvider().compactMap({ pluginEntry($0.id) }) where e.item.suggest == true && !keys.contains(Row.plugin(e).key) {
            if byPlugin[e.pluginName] == nil { suggested.append(e.pluginName) }
            if byPlugin[e.pluginName, default: []].count < 3 { byPlugin[e.pluginName, default: []].append(.plugin(e)) }
        }
        for name in suggested { out += [.header(name)] + byPlugin[name]! }
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
        case "plug":
            return pluginProvider().compactMap { pluginEntry($0.id) }.first { "\($0.pluginID):\($0.item.key)" == value }.map(Row.plugin)
        default: return nil
        }
    }

    /// Spotlight answered. Append below the instant rows, keeping the selection.
    func setFileResults(_ hits: [FileHit], for text: String) {
        guard isViewLoaded, case .search = mode, text == searchedText else { return }
        fileHits = (text, hits)
        asyncResultsChanged()
    }

    /// The page/note index answered.
    func setContentResults(_ hits: [ContentHit], for text: String) {
        guard isViewLoaded, case .search = mode, text == searchedText else { return }
        contentHits = (text, hits)
        asyncResultsChanged()
    }

    /// Plugin answers for `text` arrived. `reveal`: select the first and open the preview (an AI reply to read).
    func setPluginAnswers(_ entries: [PluginService.Entry], for text: String, reveal: Bool = false) {
        guard isViewLoaded, case .search = mode, text == searchedText else { return }
        pluginAnswers = (text, entries)
        asyncResultsChanged()
        guard reveal, let first = entries.first, let i = rows.firstIndex(where: { $0.key == Row.plugin(first).key }) else { return }
        select(row: i)
        if first.item.preview != nil { setPreview(open: true) }
    }

    private func asyncResultsChanged() {
        let previous = selectedRow.map(\.key)
        let newRows = withAsyncRows(baseRows)
        guard newRows.map(\.key) != rows.map(\.key) else { return }
        // Still on the first fallback action: the user hasn't picked it, so let an answer above it take ↵.
        let untouched = baseIsFallback && tableView.selectedRow == rows.firstIndex { !$0.isHeader }
        let before = Set(rows.map(\.key))
        rows = newRows
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        select(row: untouched ? 0 : previous.flatMap { key in rows.firstIndex { $0.key == key } } ?? 0)
        notifySize()
        fadeIn(rows.indices.filter { !before.contains(rows[$0].key) })
    }

    /// Rows that arrived on their own (files, notes, plugin answers) fade in over 80 ms instead of popping.
    /// The only motion in the panel: nothing you start from the keyboard animates.
    private func fadeIn(_ indices: [Int]) {
        guard !indices.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        tableView.layoutSubtreeIfNeeded()
        let views = indices.compactMap { tableView.rowView(atRow: $0, makeIfNecessary: false) }
        views.forEach { $0.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            views.forEach { $0.animator().alphaValue = 1 }
        }
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
        if previewOpen || layout == .grid || layout == .detail { return NSSize(width: width, height: Self.size.height) }
        let list = rows.isEmpty ? 64 : rows.reduce(0) { $0 + height(of: $1) } + 8
        return NSSize(width: width, height: min(Self.chrome + list, Self.size.height))
    }

    private func notifySize() { onPreferredSizeChange?(preferredSize) }

    private func height(of row: Row) -> CGFloat {
        if row.isScopeBar { return 40 }
        return row.isHeader ? theme.headerHeight : theme.rowHeight
    }

    // MARK: - Preview

    private func setPreview(open: Bool) {
        guard open != previewOpen, !(open && (layout == .grid || layout == .detail)) else { return }
        previewOpen = open
        if open { onFeatureUsed?("preview") }
        preview.isHidden = !open
        previewDivider.isHidden = !open
        listTrailing.isActive = !open
        if open { updatePreview() } else { preview.clear() }
        updateFooter()
        notifySize()
    }

    private func updatePreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        guard previewOpen else { return }
        if NSApp.currentEvent?.isARepeat == true {
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showPreview() }
            }
            return
        }
        showPreview()
    }

    private func showPreview() {
        previewTimer = nil
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
                return .text(title: "", facts: facts, body: pretty ?? c.content, code: true, colour: true)
            }
        case .history(let item):
            let url = historyURL(item.id) ?? ""
            return .text(title: item.title, facts: [("URL", url), ("Where", ResultCell.historySubtitle(item))], body: "", code: false)
        case .action(_, let a), .aliasAction(let a, _):
            return .text(title: a.name, facts: [("Runs", a.run)], body: "", code: false)
        case .builtin(let b, _): return .text(title: b.rawValue, facts: [("Key", b.hint)], body: "", code: false)
        case .command(let c): return .text(title: c.title, facts: [("About", c.detail)], body: "", code: false)
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
            return .text(title: c.title, facts: [("Note", c.ref)], body: body, code: false)
        case .task(let t, let project):
            return .text(title: t.name, facts: [("Runs", t.command), ("From", t.source), ("Project", project)], body: "", code: false)
        case .plugin(let e):
            let i = e.item
            var facts = [("From", e.pluginName)]
            if let sub = i.subtitle, !sub.isEmpty { facts.append(("About", sub)) }
            if let open = i.open { facts.append(("Opens", open)) } else if let run = i.run { facts.append(("Runs", run)) }
            return .text(title: i.title, facts: facts, body: i.preview ?? i.paste ?? i.copy ?? "", code: i.preview == nil)
        }
    }

    nonisolated static func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }

    // MARK: - Footer

    private func updateFooter() {
        let speed = theme.showSpeed ? lastStats : ""
        stats.stringValue = [speed, licenceNote].filter { !$0.isEmpty }.joined(separator: " · ")
        stats.isHidden = stats.stringValue.isEmpty
        if let message = notice ?? problem {
            footer.stringValue = message
            footer.isHidden = false
            hints.isHidden = true
            leadStack.isHidden = true
            return
        }
        footer.isHidden = true
        hints.isHidden = false
        leadStack.isHidden = false
        typealias H = HintBar.Hint
        var lead: [H] = []
        var showTip = false
        /// Text on the left instead of the tip (a grid's selected tile name).
        var leadText: NSAttributedString?
        defer {
            leadHints.set(lead)
            leadHints.isHidden = lead.isEmpty
            tipLabel.attributedStringValue = leadText ?? (showTip ? tipText() : NSAttributedString())
            tipLabel.isHidden = leadText == nil && !showTip
        }
        switch mode {
        case .search:
            // Two hints on the right (what ↵ does, ⌘K for the rest); ⌘/ lists every other key.
            if searchField.stringValue.isEmpty, scope == nil {
                lead = [H(key: "⌘/", label: "Shortcuts")]
                showTip = tip != nil
            } else {
                lead = [H(key: "⇥", label: scope == nil ? "Filter" : "Next source")]
                if scope != nil { lead.append(H(key: "esc", label: "All sources")) }
            }
            var list: [H] = []
            switch selectedRow {
            case .clip?, .snippet?: list.append(H(key: "↵", label: "Paste"))
            case .history(let item)?: list.append(H(key: "↵", label: "Open in \(item.subtitle.components(separatedBy: " · ").first ?? "browser")"))
            case .app?, .project?, .file?, .content?: list.append(H(key: "↵", label: "Open"))
            case .calc?, .transform?: list.append(H(key: "↵", label: "Copy"))
            case .plugin(let e)?:
                let i = e.item
                list.append(H(key: "↵", label: e.ask != nil ? "Ask" : Self.enterLabel(i)))
            case .command(let c)? where c.kind == .toggleAutoInstall || c.kind == .toggleExpansion || c.kind == .toggleOpenAtLogin
                || c.kind == .toggleDiagnostics: list.append(H(key: "↵", label: c.accessory == "On" ? "Turn off" : "Turn on"))
            case nil, .header?: break
            default: list.append(H(key: "↵", label: "Run"))
            }
            if previewOpen { list.append(H(key: "esc", label: "Close preview")) }
            if case .project? = selectedRow { list.append(H(key: "⌘K", label: "Tasks & actions")) }
            else if case .plugin(let e)? = selectedRow, let n = e.item.actions?.count { list.append(H(key: "⌘K", label: "\(n) actions")) }
            else { list.append(H(key: "⌘K", label: "Actions")) }
            hints.set(list)
        case .actions:
            hints.set([H(key: "↵", label: "Run"), H(key: "1–9", label: "Run"), H(key: "esc", label: "Back")])
        case .view:
            var list: [H] = []
            if layout == .detail {
                list = [H(key: "↵", label: "Copy"), H(key: "esc", label: "Back")]
            } else {
                if case .plugin(let e)? = selectedRow {
                    let i = e.item
                    if layout == .grid { // tiles have no captions: name the selected one here
                        leadText = NSAttributedString(string: i.title, attributes: [
                            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: theme.text,
                        ])
                    }
                    list.append(H(key: "↵", label: Self.enterLabel(i)))
                    if let n = i.actions?.count, views.last?.isActions != true { list.append(H(key: "⌘K", label: "\(n) actions")) }
                    if i.paste != nil, i.copy != nil { list.append(H(key: "⌘C", label: "Copy")) }
                    if layout == .list { list.append(H(key: previewOpen ? "esc" : "→", label: previewOpen ? "Close preview" : "Preview")) }
                }
                list.append(H(key: "esc", label: standalone && views.count == 1 ? "Close" : "Back"))
            }
            hints.set(list)
        }
        if argumentEntry != nil {
            hints.set([H(key: "tab", label: "Next field"), H(key: "↵", label: "Run"), H(key: "esc", label: "Cancel")])
        }
    }

    /// "Try 12*7  #7c5cff  1697040000": the tip's words, then its examples as code.
    private func tipText() -> NSAttributedString {
        guard let tip else { return NSAttributedString() }
        let out = NSMutableAttributedString(string: tip.text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.muted,
        ])
        for example in tip.examples {
            out.append(NSAttributedString(string: "   " + example, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: theme.subtext,
            ]))
        }
        return out
    }

    // MARK: - Selection & activation

    /// What ↵ does to a plugin item, for the footer: its own field, else its first action's title.
    private static func enterLabel(_ i: PluginItem) -> String {
        if i.open != nil { return "Open" }
        if i.paste != nil { return "Paste" }
        if i.copy != nil { return "Copy" }
        if i.run != nil { return "Run" }
        return i.actions?.first?.title ?? "Run"
    }

    private var selectedRow: Row? {
        let i = layout == .grid ? grid.selected : tableView.selectedRow
        return rows.indices.contains(i) ? rows[i] : nil
    }

    private var selectedIndex: Int { layout == .grid ? grid.selected : tableView.selectedRow }

    /// Select `row`, or the nearest result in `direction` when it's a header.
    private func select(row: Int, direction: Int = 1) {
        guard !rows.isEmpty else { updateFooter(); return }
        if layout == .grid {
            grid.selected = max(0, min(row, rows.count - 1))
            grid.scrollToSelected()
            updateFooter()
            return
        }
        var r = max(0, min(row, rows.count - 1))
        while rows.indices.contains(r), rows[r].isHeader { r += direction }
        if !rows.indices.contains(r) { // ran off the end: go the other way
            r = max(0, min(row, rows.count - 1))
            while rows.indices.contains(r), rows[r].isHeader { r -= direction }
        }
        guard rows.indices.contains(r) else { return }
        tableView.selectRowIndexes([r], byExtendingSelection: false)
        if rows[..<r].allSatisfy(\.isHeader) {
            // The first result: show everything above it (the source chips, its header), even when
            // the list is still short and the panel grows after this.
            tableView.scroll(.zero)
        } else {
            // Keep the header above the result in view.
            tableView.scrollRowToVisible(r > 0 && rows[r - 1].isHeader ? r - 1 : r)
            tableView.scrollRowToVisible(r)
        }
        updateFooter()
        updatePreview()
    }

    /// ↑/↓ in the list. Browsing opens the preview (`[appearance] auto_preview`) unless you closed it.
    private func move(by step: Int) {
        select(row: selectedIndex + step, direction: step)
        if theme.autoPreview, !previewDismissed, mode == .search || layout == .list, selectedRow != nil {
            setPreview(open: true)
        }
    }

    @objc private func activateSelection() {
        if layout == .detail, let text = views.last?.view.text {
            onCopyText?(text)
            return
        }
        guard let selected = selectedRow else { return }
        var row = selected
        if case .plugin(let e) = row, e.ask == nil, let first = e.item.actions?.first,
           e.item.open == nil, e.item.paste == nil, e.item.copy == nil, e.item.run == nil {
            // Nothing of its own to do: ↵ does its first action (asking for its fields first).
            row = .plugin(PluginService.Entry(pluginID: e.pluginID, pluginName: e.pluginName, item: first))
        }
        if case .plugin(let e) = row, !e.item.fields.isEmpty {
            beginArguments(e)
            return
        }
        if case .search = mode, let key = selected.learnKey { ranking?.record(query: query, key: key) }
        let item = modItem(for: row)
        if case .plugin = row { leaveActions() }
        activate(row, query: query)
        if let item { onChoose?(item) }
    }

    /// What a `[hotkeys]` entry opens, if it exists right now.
    func row(for hotkey: CommandHotkey) -> Row? {
        if let kind = hotkey.kind { return resolve(key: "\(kind.rawValue):\(hotkey.target)") }
        return resolve(title: hotkey.target, argument: nil)
    }

    /// Open, run or paste a row, as ↵ does. Also used by hotkeys with the panel closed.
    func activate(_ row: Row, query: String) {
        switch row {
        case .header: return
        case .clip(let item): onPaste?(item.id)
        case .history(let item): onOpenHistory?(item.id)
        case .action(_, let action): onRunAction?(action, query)
        case .aliasAction(let action, let argument): onRunAction?(action, argument)
        case .app(let item): onOpenApp?(item.subtitle)
        case .project(let p): onOpenProject?(p.path)
        case .file(let f): onOpenFile?(f.path)
        case .calc(let result, _): onFeatureUsed?("answers"); onCopyText?(result.text)
        case .transform(let t): onFeatureUsed?("answers"); onCopyText?(t.value)
        case .snippet(_, let s): onPasteText?(s.expanded(clipboard: Self.clipboardText))
        case .content(let c): onOpenNote?(c.ref)
        case .task(let t, _): onRunTask?(t)
        case .command(let c): onCommand?(c)
        case .plugin(let e): onPluginItem?(e)
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
        if argumentEntry != nil {
            switch (mods, keyCode) {
            case ([], kVK_Return), ([], kVK_ANSI_KeypadEnter): submitArguments(); return true
            case ([], kVK_Escape): endArguments(); return true
            default: return false // typing, tab
            }
        }
        let digit = HotkeyBinding.digitKeyCodes.firstIndex(of: keyCode).flatMap { $0 == 0 ? nil : $0 }
        let inActions = if case .actions = mode { true } else { false }
        if mods == [.command], keyCode == kVK_ANSI_K, !inActions, argumentEntry == nil, views.last?.isActions != true,
           case .plugin(let e)? = selectedRow, e.item.actions?.isEmpty == false {
            presentActions(for: e)
            return true
        }
        if mode == .view, mods == [.command] || mods == [] {
            // A view has no ⌘K list of its own (an item's `actions` open above); ⌘C copies a detail's text.
            if layout == .detail, mods == [.command], keyCode == kVK_ANSI_C,
               searchField.currentEditor()?.selectedRange.length ?? 0 == 0, let text = views.last?.view.text {
                onCopyText?(text)
                return true
            }
            if keyCode == kVK_ANSI_K || keyCode == kVK_Return || digit != nil, mods == [.command] { return true }
        }
        if standalone, mods == [.command], keyCode == kVK_ANSI_K { return true }

        switch (mods, keyCode) {
        case (.command, kVK_ANSI_K):
            inActions ? enterSearchMode(query: query) : enterActionsMode()
            return true
        case (.command, kVK_ANSI_Y):
            guard !inActions else { return false }
            previewDismissed = previewOpen
            setPreview(open: !previewOpen)
            return true
        case (.command, kVK_Return), (.command, kVK_ANSI_KeypadEnter):
            onFeatureUsed?("first-action")
            runAction(number: 1)
            return true
        case (.command, kVK_ANSI_Slash):
            guard mode == .search else { return false }
            showCheatSheet()
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
            case .plugin(let e)? where (e.item.copy ?? e.item.open) != nil: onCopyText?(e.item.copy ?? e.item.open!)
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
            // A plugin's [[key]] on the selected result.
            guard !inActions, !mods.isEmpty, let item = selectedRow.flatMap(modItem(for:)),
                  let hit = modKeys.first(where: { Self.matches($0.key.key, keyCode: keyCode, mods: mods) && $0.key.applies(to: item) })
            else { return false }
            onModKey?(hit.pluginID, hit.key, item)
            return true
        }
    }

    private static func matches(_ spec: HotkeySpec, keyCode: Int, mods: NSEvent.ModifierFlags) -> Bool {
        guard HotkeyBinding.keyCode(spec.key) == keyCode else { return false }
        var flags: NSEvent.ModifierFlags = []
        if spec.modifiers.contains(.command) { flags.insert(.command) }
        if spec.modifiers.contains(.option) { flags.insert(.option) }
        if spec.modifiers.contains(.control) { flags.insert(.control) }
        if spec.modifiers.contains(.shift) { flags.insert(.shift) }
        return flags == mods
    }

    /// A row as mod scripts see it: its kind, and its URL, path or text as `$1`.
    func modItem(for row: Row) -> ModItem? {
        switch row {
        case .header: return nil
        case .clip(let item):
            let c = clip(item.id)
            return ModItem(kind: "clip", title: item.title, subtitle: c?.sourceName ?? "",
                           path: c?.kind == .files ? c?.paths.first : nil, text: c?.kind == .text ? c?.content : nil)
        case .history(let item): return ModItem(kind: "history", title: item.title, url: historyURL(item.id))
        case .action(_, let a), .aliasAction(let a, _): return ModItem(kind: "action", title: a.name, text: a.run)
        case .builtin(let b, let id): return ModItem(kind: "clip", title: b.rawValue, text: clip(id)?.content)
        case .app(let item): return ModItem(kind: "app", title: item.title, path: item.subtitle)
        case .project(let p): return ModItem(kind: "project", title: p.name, path: p.path)
        case .file(let f): return ModItem(kind: "file", title: f.name, subtitle: f.folder, path: f.path)
        case .calc(let r, let expression): return ModItem(kind: "answer", title: r.text, subtitle: expression, text: r.text)
        case .transform(let t): return ModItem(kind: "answer", title: t.display, subtitle: t.label, text: t.value)
        case .snippet(_, let s): return ModItem(kind: "snippet", title: s.name, text: s.text)
        case .content(let c):
            return ModItem(kind: "note", title: c.title, path: c.ref)
        case .task(let t, let project): return ModItem(kind: "task", title: t.command, subtitle: project, text: t.commandLine)
        case .command(let c): return ModItem(kind: "command", title: c.title, subtitle: c.detail)
        case .plugin(let e):
            let i = e.item
            let path = i.open.map { ($0 as NSString).expandingTildeInPath }.flatMap { $0.hasPrefix("/") ? $0 : nil }
            return ModItem(kind: "plugin", title: i.title, subtitle: i.subtitle ?? "", url: path == nil ? i.open : nil, path: path,
                           text: i.copy ?? i.paste, pluginID: e.pluginID)
        }
    }

    /// The file whose icon a row shows (beyond `Row.path`): a copied file's first path.
    private func iconPath(_ row: Row) -> String? {
        if case .plugin(let e) = row { return PluginIcon.appPath(e.item.icon) }
        guard case .clip(let item) = row, let c = clip(item.id) else { return nil }
        if c.kind == .files { return c.paths.first }
        return c.sourceBundleID.map { "bundle:\($0)" }
    }
}

extension LauncherViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField else { return }
        runSearch()
        if mode == .view, views.last?.view.search != nil { scheduleSearch() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false } // an argument field: tab, typing
        if layout == .grid {
            let step = switch selector {
            case #selector(NSResponder.moveUp(_:)): -grid.columns
            case #selector(NSResponder.moveDown(_:)): grid.columns
            case #selector(NSResponder.moveLeft(_:)): -1
            case #selector(NSResponder.moveRight(_:)): 1
            default: 0
            }
            if step != 0 {
                let next = grid.selected + step
                if rows.indices.contains(next) { select(row: next) }
                return true
            }
        }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveRight(_:)):
            // → at the end of the text opens the preview; anywhere else it moves the caret.
            let r = textView.selectedRange()
            guard !previewOpen, mode == .search || layout == .list, selectedRow != nil, r.length == 0,
                  r.location == (textView.string as NSString).length
            else { return false }
            previewDismissed = false
            setPreview(open: true)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            guard mode == .search else { return false }
            tabScope(backwards: selector == #selector(NSResponder.insertBacktab(_:)))
        case #selector(NSResponder.deleteBackward(_:)):
            // ⌫ on an empty search drops the source filter.
            guard mode == .search, scope != nil, textView.string.isEmpty else { return false }
            setScope(nil, query: "")
        case #selector(NSResponder.cancelOperation(_:)):
            if previewOpen { setPreview(open: false); previewDismissed = true }
            else if mode == .search, scope != nil { setScope(nil, query: searchField.stringValue) }
            else if case .actions = mode { enterSearchMode(query: query) }
            else if mode == .view { popView() }
            else { onClose?() }
        default: return false
        }
        return true
    }
}

extension LauncherViewController: NSComboBoxDelegate {}

extension LauncherViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) ? height(of: rows[row]) : theme.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !rows[row].isHeader }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ResultRowView()
        view.accent = theme.accent
        view.fill = theme.selection
        view.isHeader = rows[row].isHeader
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        if r.isScopeBar {
            let cell = tableView.makeView(withIdentifier: ScopeBarCell.id, owner: nil) as? ScopeBarCell ?? ScopeBarCell()
            cell.configure(availableScopes, theme: theme)
            cell.onPick = { [weak self] scope in self?.setScope(scope, query: "") }
            cell.onMore = { [weak self] in self?.showCheatSheet() }
            return cell
        }
        if case .header(let title) = r {
            let cell = tableView.makeView(withIdentifier: SectionHeaderCell.id, owner: nil) as? SectionHeaderCell ?? SectionHeaderCell()
            cell.configure(title, theme: theme)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell ?? ResultCell()
        let inActions = if case .actions = mode { true } else { false }
        let highlight: String? = inActions ? searchField.stringValue : searchField.stringValue.isEmpty ? nil : searchField.stringValue
        let tint = theme.tint(for: r)
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
            default:
                // The app it came from, as its icon: five copies from Ghostty read as Ghostty at a glance.
                let app = c?.sourceBundleID.flatMap { IconCache.shared.icon(forBundleID: $0) }
                show("doc.on.clipboard", image: app, item.title, ResultCell.clipSubtitle(item, showsApp: app != nil))
            }
        case .history(let item):
            let host = URL(string: historyURL(item.id) ?? "")?.host()?.lowercased() ?? ""
            let browser = item.subtitle.components(separatedBy: " · ").first ?? ""
            show("globe", image: favicon(host), item.title, detail: host,
                 [browser, ResultCell.historyAge(item)].filter { !$0.isEmpty }.joined(separator: " · "))
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
            // A folder glyph on a plate like every other row; the Finder icon of a repo is a blank page or folder.
            show("folder", p.name,
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
            show("note.text", c.title, detail: c.snippet, "Note", plain: true)
        case .task(let t, _):
            show("hammer", t.name, detail: t.command, t.source)
        case .command(let c):
            show(c.symbol, c.title, detail: c.detail, c.accessory.isEmpty ? "Command" : c.accessory)
        case .plugin(let e):
            let image = PluginIcon.image(e.item.icon, directory: pluginDirectory(e.pluginID))
            let symbol = PluginIcon.appPath(e.item.icon) != nil ? "app" : e.item.icon ?? "puzzlepiece.extension"
            show(image == nil ? symbol : "puzzlepiece.extension", image: image, e.item.title,
                 detail: e.item.subtitle ?? "", tagged(e.item.label ?? e.pluginName, title: e.item.title))
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
        updatePreview()
    }

    /// "Application" → "code · Application" when it has an alias.
    private func tagged(_ label: String, title: String) -> String {
        let t = title.lowercased()
        let hotkey = hotkeys.first { $0.target.lowercased() == t }?.hotkey.symbols
        return [hotkey, aliases.alias(for: title), label.isEmpty ? nil : label].compactMap { $0 }.joined(separator: " · ")
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
