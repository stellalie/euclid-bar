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

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 7
        icon.imageScaling = .scaleProportionallyUpOrDown
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
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.setContentHuggingPriority(.required, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [chip, icon, title, detail, subtitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 22)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 22)
        chipSize = chip.widthAnchor.constraint(equalToConstant: 28)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chipSize,
            chip.heightAnchor.constraint(equalTo: chip.widthAnchor),
            icon.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            iconWidth, iconHeight,
            title.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 12),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// `image` (an app/file icon, favicon or thumbnail) wins over the `symbol` placeholder when it's loaded.
    /// `highlight` is the query whose matched letters are drawn bold in `accent`.
    func configure(icon symbol: String, image: NSImage? = nil, tint: NSColor = .secondaryLabelColor, title text: String,
                   detail extra: String = "", accessory: String, highlight: String? = nil, theme: Theme) {
        let iconSize = theme.iconSize
        chipSize.constant = iconSize + 6
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
            icon.symbolConfiguration = .init(pointSize: iconSize * 0.62, weight: .semibold)
            chip.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
            iconWidth.constant = iconSize * 0.8
            iconHeight.constant = iconSize * 0.8
        }
        // Never lay out megabytes: show the first non-empty line, capped.
        let firstLine = text.prefix(300).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let shown = firstLine.trimmingCharacters(in: .whitespaces)
        let font = NSFont.systemFont(ofSize: theme.titleSize)
        let attributed = NSMutableAttributedString(string: shown, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let highlight, !highlight.isEmpty {
            let bold = NSFont.systemFont(ofSize: theme.titleSize, weight: .bold)
            for r in FuzzyMatcher.matchRanges(query: highlight, in: shown) {
                attributed.addAttributes([.font: bold, .foregroundColor: theme.accent], range: NSRange(r, in: shown))
            }
        }
        title.attributedStringValue = attributed
        detail.stringValue = extra
        subtitle.stringValue = accessory
    }

    static func clipSubtitle(_ item: SearchItem) -> String {
        let age = item.date.map { ageFormatter.localizedString(for: $0, relativeTo: Date()) }
        return [item.subtitle, age].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// "Dia · github.com · visited 2h ago"
    static func historySubtitle(_ item: SearchItem) -> String {
        let visited = item.date.map { "visited \(RelativeAge.short($0))" }
        return [item.subtitle, visited].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// Small caps section title above a group of rows.
final class SectionHeaderCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("SectionHeader")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) { label.stringValue = text.uppercased() }
}

/// Selection drawn as a soft rounded pill in the accent colour, not the stock solid blue.
/// Never "emphasized", so text keeps its normal colours on the selected row.
final class ResultRowView: NSTableRowView {
    var accent: NSColor = .controlAccentColor
    var isHeader = false

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isHeader else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        accent.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

/// A key drawn as a small rounded keycap, e.g. ⌘K.
final class KeycapView: NSView {
    private let text: NSAttributedString

    init(_ key: String) {
        text = NSAttributedString(string: key, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = text.size()
        return NSSize(width: max(ceil(s.width) + 10, 18), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
        let s = text.size()
        text.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }
}

/// The footer's shortcut hints: keycap + label pairs.
final class HintBar: NSStackView {
    private var current: [Hint] = []

    struct Hint: Equatable {
        let key: String
        let label: String
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 14
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
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            let pair = NSStackView(views: [KeycapView(hint.key), label])
            pair.spacing = 5
            pair.alignment = .centerY
            // Later hints give way first when space runs out.
            addArrangedSubview(pair)
            setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(1000 - i * 10)), for: pair)
        }
    }
}
