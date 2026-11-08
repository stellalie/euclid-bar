import AppKit
import EuclidCore

/// The source the search is narrowed to, as a chip before the typed text ("Clipboard").
final class ScopeChipView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ scope: SearchScope, theme: Theme) {
        icon.image = NSImage(systemSymbolName: scope.symbol, accessibilityDescription: nil)
        label.stringValue = scope.title
        label.textColor = theme.accent
        icon.contentTintColor = theme.accent
        resolving { layer?.backgroundColor = theme.accent.withAlphaComponent(0.16).cgColor }
    }
}

/// The empty bar's map of what it searches: one row of source chips (click or ⇥ to narrow),
/// then "+ N more" for the rest and every shortcut (⌘/). Gone on the first keystroke.
/// Drag a chip sideways to reorder; the order is saved as `[search] sources`, which ⇥ follows too.
final class ScopeBarCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ScopeBar")
    /// How many sources fit on the row before "+ N more" (with their glyphs, at the narrowest panel).
    static let shown = 5

    private let stack = NSStackView()
    private var leading: NSLayoutConstraint!
    private var scopes: [SearchScope] = []
    private var theme = Theme()
    var onPick: ((SearchScope) -> Void)?
    var onMore: (() -> Void)?
    /// A chip was dropped somewhere new: every source, in the new order.
    var onReorder: (([SearchScope]) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            leading,
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        ResultCell.align(leading, in: self)
        super.layout()
    }

    func configure(_ scopes: [SearchScope], theme: Theme) {
        self.scopes = scopes
        self.theme = theme
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, scope) in scopes.prefix(Self.shown).enumerated() {
            let p = pill(scope.title, symbol: scope.symbol, tag: i, theme: theme)
            p.onDrag = { [weak self, weak p] event in if let self, let p { self.drag(p, from: event) } }
            p.toolTip = "Click to search only \(scope.title) · drag to reorder"
            stack.addArrangedSubview(p)
        }
        let more = scopes.count - Self.shown
        stack.addArrangedSubview(pill(more > 0 ? "+ \(more) more" : "All shortcuts", symbol: nil, tag: -1, theme: theme))
        // How to get there without the mouse.
        let hint = NSTextField(labelWithString: "⇥")
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.textColor = theme.muted
        hint.toolTip = "⇥ narrows to the next source"
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(hint)
    }

    /// A rounded pill: the source's glyph and name on a plate with a hairline edge, so it reads as a button.
    private func pill(_ title: String, symbol: String?, tag: Int, theme: Theme) -> SourcePill {
        let b = SourcePill(title: title, target: self, action: #selector(clicked(_:)))
        b.tag = tag
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 13
        b.layer?.borderWidth = 1
        resolving {
            b.layer?.backgroundColor = theme.chipFill.cgColor
            b.layer?.borderColor = theme.subtext.withAlphaComponent(0.28).cgColor // visible on dark glass too
        }
        b.attributedTitle = NSAttributedString(string: symbol == nil ? title : " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: theme.subtext,
        ])
        var width = ceil(b.attributedTitle.size().width) + 24
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            b.image = image
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.contentTintColor = theme.subtext
            width += image.size.width + 5
        }
        b.refusesFirstResponder = true // typing stays in the search field
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.heightAnchor.constraint(equalToConstant: 26),
            b.widthAnchor.constraint(equalToConstant: width),
        ])
        return b
    }

    @objc private func clicked(_ sender: NSButton) {
        if scopes.indices.contains(sender.tag) { onPick?(scopes[sender.tag]) } else { onMore?() }
    }

    /// Follows the mouse until it's let go: the chip slides past its neighbours as you cross their middles,
    /// and a drop somewhere new saves the order. A press that never moves is a click.
    private func drag(_ pill: SourcePill, from down: NSEvent) {
        guard let window else { return }
        var pills: [SourcePill] { stack.arrangedSubviews.compactMap { $0 as? SourcePill }.filter { $0.onDrag != nil } }
        let start = down.locationInWindow
        var dragging = false
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let x = stack.convert(event.locationInWindow, from: nil).x
            if event.type == .leftMouseUp { break }
            if !dragging {
                guard abs(event.locationInWindow.x - start.x) > 4 else { continue }
                dragging = true
                pill.alphaValue = 0.6
                NSCursor.closedHand.set()
            }
            // Where it lands: before the first other chip whose middle is right of the mouse.
            let others = pills.filter { $0 !== pill }
            let target = others.firstIndex { x < $0.frame.midX } ?? others.count
            if target != pills.firstIndex(of: pill) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    ctx.allowsImplicitAnimation = true
                    stack.removeArrangedSubview(pill)
                    stack.insertArrangedSubview(pill, at: target)
                    stack.layoutSubtreeIfNeeded()
                }
            }
        }
        guard dragging else { pill.performClick(nil); return }
        NSCursor.arrow.set()
        pill.alphaValue = 1
        let shown = pills.map { scopes[$0.tag] }
        let reordered = shown + scopes.filter { !shown.contains($0) }
        guard reordered != scopes else { return }
        configure(reordered, theme: theme) // tags follow the new order
        onReorder?(reordered)
    }
}

/// A source chip: a button that hands a press to its row, which tells a click from a drag.
final class SourcePill: NSButton {
    var onDrag: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let onDrag { onDrag(event) } else { super.mouseDown(with: event) }
    }
}

/// The panel's root view: tells the controller when light/dark flips, so layer colours follow.
final class PanelRootView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
