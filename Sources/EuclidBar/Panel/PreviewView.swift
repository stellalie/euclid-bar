import AppKit
import Quartz

/// The right-hand pane opened with → or ⌘Y: full text, an image, or a Quick Look preview.
@MainActor
final class PreviewView: NSView {
    enum Content {
        /// Title, then "label: value" lines, then a body (monospaced when `code`).
        case text(title: String, facts: [(String, String)], body: String, code: Bool)
        case image(NSImage, title: String)
        case quickLook(URL)
        case none
    }

    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private var quickLook: QLPreviewView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
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

    func show(_ content: Content) {
        textScroll.isHidden = true
        imageView.isHidden = true
        quickLook?.isHidden = true
        switch content {
        case .text(let title, let facts, let body, let code):
            textView.textStorage?.setAttributedString(Self.render(title: title, facts: facts, body: body, code: code))
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

    private static func render(title: String, facts: [(String, String)], body: String, code: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 4
        if !title.isEmpty {
            out.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
            ]))
        }
        for (label, value) in facts {
            out.append(NSAttributedString(string: label + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            out.append(NSAttributedString(string: value + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        if !body.isEmpty {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            // Never lay out megabytes.
            let shown = body.count > 100_000 ? String(body.prefix(100_000)) + "\n…" : body
            out.append(NSAttributedString(string: shown, attributes: [
                .font: code ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        return out
    }
}
