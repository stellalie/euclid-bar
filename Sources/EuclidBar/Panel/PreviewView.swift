import AppKit
import Quartz

/// The right-hand card opened with → or ⌘Y: full text, an image, or a Quick Look preview,
/// on its own darker surface. Short copied code gets light syntax colour; facts sit in a two-column grid.
@MainActor
final class PreviewView: NSView {
    enum Content {
        /// Title, then "label: value" lines, then a body (monospaced when `code`;
        /// syntax-coloured when `colour`, for copied text only, never a plugin's or Euclid's own lists).
        case text(title: String, facts: [(String, String)], body: String, code: Bool, colour: Bool = false)
        case image(NSImage, title: String)
        case quickLook(URL)
        case none
    }

    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private var quickLook: QLPreviewView?
    var theme = Theme()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.scrollerStyle = .overlay
        imageView.imageScaling = .scaleProportionallyDown
        for v in [textScroll, imageView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The card's fill, as the panel looks now.
    func applyCard() {
        resolving { layer?.backgroundColor = theme.cardFill.cgColor }
    }

    func show(_ content: Content) {
        textScroll.isHidden = true
        imageView.isHidden = true
        quickLook?.isHidden = true
        switch content {
        case .text(let title, let facts, let body, let code, let colour):
            textView.textStorage?.setAttributedString(render(title: title, facts: facts, body: body, code: code, colour: colour))
            textView.scroll(.zero)
            textScroll.isHidden = false
        case .image(let image, _):
            imageView.image = image
            imageView.isHidden = false
        case .quickLook(let url):
            let ql = quickLook ?? makeQuickLook()
            ql.previewItem = url as NSURL
            ql.isHidden = false
        case .none:
            textView.string = ""
            textScroll.isHidden = false
        }
    }

    /// Stop Quick Look's work when the pane closes.
    func clear() {
        quickLook?.previewItem = nil
        imageView.image = nil
    }

    private func makeQuickLook() -> QLPreviewView {
        let ql = QLPreviewView(frame: bounds, style: .compact)!
        ql.autostarts = true
        ql.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ql)
        NSLayoutConstraint.activate([
            ql.leadingAnchor.constraint(equalTo: leadingAnchor),
            ql.trailingAnchor.constraint(equalTo: trailingAnchor),
            ql.topAnchor.constraint(equalTo: topAnchor),
            ql.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        quickLook = ql
        return ql
    }

    private func render(title: String, facts: [(String, String)], body: String, code: Bool, colour: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 8
        if !title.isEmpty {
            out.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: theme.text, .paragraphStyle: para,
            ]))
        }
        // Label and value in two columns.
        let grid = NSMutableParagraphStyle()
        grid.tabStops = [NSTextTab(textAlignment: .left, location: 72)]
        grid.headIndent = 72
        grid.lineBreakMode = .byCharWrapping
        grid.paragraphSpacing = 4
        for (label, value) in facts {
            out.append(NSAttributedString(string: label + "\t", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.subtext, .paragraphStyle: grid,
            ]))
            out.append(NSAttributedString(string: value + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.text, .paragraphStyle: grid,
            ]))
        }
        if !body.isEmpty {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            // Never lay out megabytes.
            let shown = body.count > 100_000 ? String(body.prefix(100_000)) + "\n…" : body
            let lines = NSMutableParagraphStyle()
            lines.lineSpacing = code ? 3 : 2
            let text = NSMutableAttributedString(string: shown, attributes: [
                .font: code ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13),
                .foregroundColor: theme.text, .paragraphStyle: lines,
            ])
            if code && colour { highlight(text) }
            out.append(text)
        }
        return out
    }

    /// Light syntax colour for short code (≤ 2 KB, so it costs well under a millisecond):
    /// strings, numbers, --flags, JSON keys, and the command word that starts a line.
    private func highlight(_ text: NSMutableAttributedString) {
        guard text.length <= 2_048 else { return }
        let ns = text.string as NSString
        func paint(_ pattern: String, _ color: NSColor, group: Int = 0) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            for m in re.matches(in: text.string, range: NSRange(location: 0, length: ns.length)) {
                text.addAttribute(.foregroundColor, value: color, range: m.range(at: group))
            }
        }
        let green = theme.colors["green"] ?? .systemGreen
        let orange = theme.colors["orange"] ?? .systemOrange
        let purple = theme.colors["purple"] ?? .systemPurple
        paint(#"^\s*([A-Za-z_][\w.-]*)(?=\s|$)"#, theme.accent, group: 1) // the command
        paint(#"(?<=\s)--?[A-Za-z][\w-]*"#, purple) // flags
        paint(#"\b\d+(\.\d+)?\b"#, orange) // numbers
        paint(#""[^"\n]*"|'[^'\n]*'"#, green) // strings
        paint(#"("[^"\n]*")\s*:"#, theme.accent, group: 1) // JSON keys
    }
}
