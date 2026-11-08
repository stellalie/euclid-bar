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
/// then "+ N more", which pages the row to the rest of the sources, "All shortcuts" (⌘/) and ‹ back.
/// Gone on the first keystroke.
final class ScopeBarCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ScopeBar")
    /// How many sources fit on the row before "+ N more" (with their glyphs, at the narrowest panel).
    static let shown = 5

    private let stack = NSStackView()
    private var leading: NSLayoutConstraint!
    private var scopes: [SearchScope] = []
    var onPick: ((SearchScope) -> Void)?
    var onMore: (() -> Void)?
    /// The row is showing the sources past the first `shown`; the controller keeps it so a reload keeps the page.
    var onPage: ((Bool) -> Void)?
    private static let back = -2, more = -1, all = -3

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

    func configure(_ scopes: [SearchScope], expanded: Bool, theme: Theme) {
        self.scopes = scopes
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let more = scopes.count - Self.shown
        if expanded && more > 0 {
            stack.addArrangedSubview(pill("‹", symbol: nil, tag: Self.back, theme: theme))
            for (i, scope) in scopes.enumerated().dropFirst(Self.shown) {
                stack.addArrangedSubview(pill(scope.title, symbol: scope.symbol, tag: i, theme: theme))
            }
            stack.addArrangedSubview(pill("All shortcuts", symbol: nil, tag: Self.all, theme: theme))
        } else {
            for (i, scope) in scopes.prefix(Self.shown).enumerated() {
                stack.addArrangedSubview(pill(scope.title, symbol: scope.symbol, tag: i, theme: theme))
            }
            stack.addArrangedSubview(more > 0
                ? pill("+ \(more) more", symbol: nil, tag: Self.more, theme: theme)
                : pill("All shortcuts", symbol: nil, tag: Self.all, theme: theme))
        }
        // How to get there without the mouse.
        let hint = NSTextField(labelWithString: "⇥")
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.textColor = theme.muted
        hint.toolTip = "⇥ narrows to the next source"
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(hint)
    }

    /// A rounded pill: the source's glyph and name on a plate with a hairline edge, so it reads as a button.
    private func pill(_ title: String, symbol: String?, tag: Int, theme: Theme) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(clicked(_:)))
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
        switch sender.tag {
        case Self.more: onPage?(true)
        case Self.back: onPage?(false)
        case Self.all: onMore?()
        default: if scopes.indices.contains(sender.tag) { onPick?(scopes[sender.tag]) }
        }
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
