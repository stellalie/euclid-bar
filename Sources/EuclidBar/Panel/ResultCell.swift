import AppKit
import EuclidCore

/// Reused row view: an icon chip, a title (matched letters highlighted), a dimmer
/// detail right after it, and a trailing accessory.
final class ResultCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ResultCell")

    private let chip = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    private var chipSize: NSLayoutConstraint!
    private var chipLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 6
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.init(rawValue: 251), for: .horizontal) // truncate the detail first
        title.setContentHuggingPriority(.required, for: .horizontal)
        detail.font = .systemFont(ofSize: 12.5)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 1
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitle.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.setContentHuggingPriority(.required, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [chip, icon, title, detail, subtitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 22)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 22)
        chipSize = chip.widthAnchor.constraint(equalToConstant: 24)
        chipLeading = chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            chipLeading,
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chipSize,
            chip.heightAnchor.constraint(equalTo: chip.widthAnchor),
            icon.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            iconWidth, iconHeight,
            title.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 12),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Line the icon up with the typed text and section names, wherever the table puts the cell.
    override func layout() {
        Self.align(chipLeading, in: self)
        super.layout()
    }

    /// Sets `leading` so the view it places starts `Theme.gutter` from the window's left edge.
    static func align(_ leading: NSLayoutConstraint, in cell: NSView) {
        guard cell.window != nil else { return }
        let want = max(0, Theme.gutter - cell.convert(NSPoint.zero, to: nil).x)
        if abs(leading.constant - want) > 0.5 { leading.constant = want }
    }

    /// `image` (an app/file icon, favicon or thumbnail) wins over the `symbol` placeholder when it's loaded.
    /// `highlight` is the query whose matched letters are drawn bold in `accent`.
    func configure(icon symbol: String, image: NSImage? = nil, tint: NSColor = .secondaryLabelColor, title text: String,
                   detail extra: String = "", accessory: String, highlight: String? = nil, theme: Theme) {
        let iconSize = theme.iconSize
        chipSize.constant = iconSize
        if let image {
            icon.image = image
            icon.contentTintColor = nil
            icon.symbolConfiguration = nil
            chip.layer?.backgroundColor = nil
            iconWidth.constant = iconSize
            iconHeight.constant = iconSize
        } else {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = tint
            icon.symbolConfiguration = .init(pointSize: iconSize * 0.56, weight: .medium)
            resolving { chip.layer?.backgroundColor = theme.chipFill.cgColor }
            iconWidth.constant = iconSize * 0.72
            iconHeight.constant = iconSize * 0.72
        }
        // Never lay out megabytes: show the first non-empty line, capped.
        let firstLine = text.prefix(300).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let shown = firstLine.trimmingCharacters(in: .whitespaces)
        let font = NSFont.systemFont(ofSize: theme.titleSize)
        // Matches are told by weight, not colour. (Not by a dimmer rest either: a dynamic colour with
        // alpha can resolve dark on a selected row.)
        let ranges = highlight.map { $0.isEmpty ? [] : FuzzyMatcher.displayRanges(query: $0, in: shown) } ?? []
        let attributed = NSMutableAttributedString(string: shown, attributes: [.font: font, .foregroundColor: theme.text])
        let bold = NSFont.systemFont(ofSize: theme.titleSize, weight: .semibold)
        for r in ranges { attributed.addAttribute(.font, value: bold, range: NSRange(r, in: shown)) }
        title.attributedStringValue = attributed
        detail.textColor = theme.muted
        subtitle.textColor = theme.muted
        detail.stringValue = extra
        subtitle.stringValue = accessory
    }

    /// "Ghostty · 2m", or just "2m" when the row already shows Ghostty's icon.
    static func clipSubtitle(_ item: SearchItem, showsApp: Bool = false) -> String {
        let age = item.date.map { RelativeAge.compact($0) }
        return [showsApp ? nil : item.subtitle, age].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// The right-hand column of a history row: "40m" (the host goes in the detail).
    static func historyAge(_ item: SearchItem) -> String { item.date.map { RelativeAge.compact($0) } ?? "" }

    /// "Dia · github.com · visited 2h ago"
    static func historySubtitle(_ item: SearchItem) -> String {
        let visited = item.date.map { "visited \(RelativeAge.short($0))" }
        return [item.subtitle, visited].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

}

/// A quiet sentence-case section title above a group of rows, on the same left edge as the icons.
final class SectionHeaderCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("SectionHeader")
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            leading,
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        ResultCell.align(leading, in: self)
        super.layout()
    }

    func configure(_ text: String, theme: Theme) {
        label.stringValue = text
        label.textColor = theme.muted
    }
}

/// Selection drawn as a soft rounded pill with a thin accent ring, not the stock solid blue.
/// Never "emphasized", so text keeps its normal colours on the selected row.
/// Its corners are concentric with the panel's (16 pt panel, 8 pt in → 8 pt).
final class ResultRowView: NSTableRowView {
    var accent: NSColor = .controlAccentColor
    /// The theme's own selection colour; nil = a faint accent.
    var fill: NSColor?
    var isHeader = false

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isHeader else { return }
        let rect = bounds.insetBy(dx: 2, dy: 1)
        (fill ?? accent.withAlphaComponent(0.16)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
        ring.lineWidth = 1
        accent.withAlphaComponent(0.3).setStroke()
        ring.stroke()
    }
}

/// A key drawn as a small rounded keycap, e.g. ⌘K.
final class KeycapView: NSView {
    private let text: NSAttributedString
    private let ink: NSColor

    init(_ key: String, theme: Theme) {
        text = NSAttributedString(string: key, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: theme.subtext,
        ])
        ink = theme.text
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = text.size()
        return NSSize(width: max(ceil(s.width) + 10, 19), height: 19)
    }

    override func draw(_ dirtyRect: NSRect) {
        ink.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let s = text.size()
        text.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }
}

/// The footer's shortcut hints: keycap + label pairs.
final class HintBar: NSStackView {
    private var current: [Hint] = []
    var theme = Theme() {
        didSet { let hints = current; current = []; set(hints) }
    }

    struct Hint: Equatable {
        let key: String
        let label: String
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 16
        alignment = .centerY
        setHuggingPriority(.defaultLow, for: .horizontal)
        setClippingResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(_ hints: [Hint]) {
        guard hints != current else { return } // called on every selection change
        current = hints
        for v in arrangedSubviews { removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, hint) in hints.enumerated() {
            let label = NSTextField(labelWithString: hint.label)
            label.font = .systemFont(ofSize: 12)
            label.textColor = theme.subtext
            label.lineBreakMode = .byTruncatingTail
            let pair = NSStackView(views: [KeycapView(hint.key, theme: theme), label])
            pair.spacing = 6
            pair.alignment = .centerY
            // Later hints give way first when space runs out.
            addArrangedSubview(pair)
            setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(1000 - i * 10)), for: pair)
        }
    }
}
