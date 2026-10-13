import AppKit
import EuclidCore

@MainActor
final class LauncherViewController: NSViewController {
    static let size = NSSize(width: 680, height: 440)

    var onClose: (() -> Void)?
    var onPaste: ((Int) -> Void)?
    var onCopy: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?

    private let itemsProvider: () -> [SearchItem]
    private var results: [SearchItem] = []
    private var keyMonitor: Any?

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "↵ Paste    ⌘C Copy    ⌘⌫ Delete    esc Close")

    init(items: @escaping () -> [SearchItem]) {
        self.itemsProvider = items
        super.init(nibName: nil, bundle: nil)
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
        searchField.placeholderString = "Search clipboard, calculate, or ask AI…"
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.delegate = self

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
        footer.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor

        for v in [searchField, divider, scrollView, emptyLabel, footerDivider, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

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
        runSearch()
    }

    /// Called right before the panel is shown: clear the query, focus the field.
    func prepareForShow() {
        searchField.stringValue = ""
        runSearch()
        view.window?.makeFirstResponder(searchField)
    }

    /// History changed while the panel may be visible: refresh, keep the selected entry if it survived.
    func reload() {
        guard isViewLoaded else { return }
        let selectedID = results.indices.contains(tableView.selectedRow) ? results[tableView.selectedRow].id : nil
        runSearch()
        if let selectedID, let row = results.firstIndex(where: { $0.id == selectedID }) { select(row: row) }
    }

    private func runSearch() {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("search")
        let all = itemsProvider()
        results = FuzzyMatcher.search(searchField.stringValue, in: all)
        tableView.reloadData()
        select(row: 0)
        emptyLabel.stringValue = all.isEmpty ? "Copy something — it will show up here." : "No matches"
        emptyLabel.isHidden = !results.isEmpty
        tableView.displayIfNeeded()
        signposter.endInterval("search", state)
        perfLog.notice("search -> \(self.results.count) of \(all.count) rows in \(String(describing: ContinuousClock.now - start), privacy: .public)")
    }

    private func select(row: Int) {
        guard !results.isEmpty else { return }
        let r = max(0, min(row, results.count - 1))
        tableView.selectRowIndexes([r], byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
    }

    private var selectedID: Int? {
        results.indices.contains(tableView.selectedRow) ? results[tableView.selectedRow].id : nil
    }

    @objc private func activateSelection() {
        if let id = selectedID { onPaste?(id) }
    }

    /// ⌘C (copy entry, unless text is selected in the field) and ⌘⌫ (delete entry).
    /// Handled here because they're key equivalents, which bypass the text field delegate.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            let keyCode = event.keyCode
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let window = event.window.map(ObjectIdentifier.init)
            let consumed = MainActor.assumeIsolated {
                self?.handleKey(keyCode: keyCode, mods: mods, window: window) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func handleKey(keyCode: UInt16, mods: NSEvent.ModifierFlags, window: ObjectIdentifier?) -> Bool {
        guard let own = view.window, window == ObjectIdentifier(own),
              mods == .command, let id = selectedID else { return false }
        switch keyCode {
        case 8: // C
            if let editor = searchField.currentEditor(), editor.selectedRange.length > 0 { return false } // normal text copy
            onCopy?(id)
            return true
        case 51: // Delete
            let row = tableView.selectedRow
            onDelete?(id)
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
        case #selector(NSResponder.cancelOperation(_:)): onClose?()
        default: return false
        }
        return true
    }
}

extension LauncherViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell ?? ResultCell()
        cell.configure(results[row])
        return cell
    }
}

/// Reused row view: icon + single-line title + trailing subtitle.
final class ResultCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ResultCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.setContentHuggingPriority(.required, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [icon, title, subtitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: SearchItem) {
        // Never lay out megabytes: show the first non-empty line, capped.
        let firstLine = item.title.prefix(300).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title.stringValue = firstLine.trimmingCharacters(in: .whitespaces)
        let age = item.date.map { Self.ageFormatter.localizedString(for: $0, relativeTo: Date()) }
        subtitle.stringValue = [item.subtitle, age].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
