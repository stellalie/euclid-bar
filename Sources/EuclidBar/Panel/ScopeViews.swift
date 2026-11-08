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
final class ScopeBarCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ScopeBar")
    /// How many sources fit on the row before "+ N more".
    static let shown = 6

    private let stack = NSStackView()
    private var leading: NSLayoutConstraint!
    private var scopes: [SearchScope] = []
    var onPick: ((SearchScope) -> Void)?
    var onMore: (() -> Void)?

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
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, scope) in scopes.prefix(Self.shown).enumerated() {
            stack.addArrangedSubview(pill(scope.title, tag: i, theme: theme))
        }
        let more = scopes.count - Self.shown
        stack.addArrangedSubview(pill(more > 0 ? "+ \(more) more" : "All shortcuts", tag: -1, theme: theme))
    }

    private func pill(_ title: String, tag: Int, theme: Theme) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(clicked(_:)))
        b.tag = tag
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 13
        resolving { b.layer?.backgroundColor = theme.chipFill.cgColor }
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: theme.subtext,
        ])
        b.refusesFirstResponder = true // typing stays in the search field
        b.translatesAutoresizingMaskIntoConstraints = false
        let width = ceil(b.attributedTitle.size().width) + 22
        NSLayoutConstraint.activate([
            b.heightAnchor.constraint(equalToConstant: 26),
            b.widthAnchor.constraint(equalToConstant: width),
        ])
        return b
    }

    @objc private func clicked(_ sender: NSButton) {
        if scopes.indices.contains(sender.tag) { onPick?(scopes[sender.tag]) } else { onMore?() }
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
