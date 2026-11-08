import AppKit
import EuclidCore

/// A plugin view's items as tiles: just a big icon (emoji, image or symbol). The selected tile's
/// title is in the footer, so the grid isn't a wall of cut-off labels.
/// Drawn in one view (only the visible rows), so a grid of 2,000 emoji costs nothing to show.
/// The search field keeps the keyboard; the panel moves `selected` with the arrow keys.
@MainActor
final class GridView: NSView {
    var entries: [PluginService.Entry] = [] { didSet { relayout() } }
    var columns = PluginView.defaultColumns { didSet { if columns != oldValue { relayout() } } }
    var selected = 0 {
        didSet {
            guard selected != oldValue else { return }
            setNeedsDisplay(tileRect(oldValue).insetBy(dx: -2, dy: -2))
            setNeedsDisplay(tileRect(selected).insetBy(dx: -2, dy: -2))
        }
    }
    var theme = Theme() { didSet { needsDisplay = true } }
    /// The icon as an image (a file or an emoji); nil = draw it as an SF Symbol.
    var image: (PluginService.Entry) -> NSImage? = { _ in nil }
    var onSelect: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?

    private static let inset: CGFloat = 8
    /// Tiles are a little wider than tall.
    private static let aspect: CGFloat = 0.82

    override var isFlipped: Bool { true }

    private var tileWidth: CGFloat { max(40, ((bounds.width - Self.inset * 2) / CGFloat(columns)).rounded(.down)) }
    private var tileHeight: CGFloat { (tileWidth * Self.aspect).rounded() }
    private var rowCount: Int { (entries.count + columns - 1) / columns }

    func tileRect(_ i: Int) -> NSRect {
        guard i >= 0 else { return .zero }
        return NSRect(x: Self.inset + CGFloat(i % columns) * tileWidth, y: Self.inset + CGFloat(i / columns) * tileHeight,
                      width: tileWidth, height: tileHeight)
    }

    /// Tall enough for every row (and at least the visible area, so clicks below land here).
    private func relayout() {
        setFrameSize(frame.size)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let visible = enclosingScrollView?.contentSize.height ?? 0
        let width = newSize.width
        let tile = max(40, ((width - Self.inset * 2) / CGFloat(columns)).rounded(.down))
        let rows = CGFloat((entries.count + columns - 1) / columns)
        let height = max(visible, Self.inset * 2 + rows * (tile * Self.aspect).rounded())
        super.setFrameSize(NSSize(width: width, height: height))
    }

    func scrollToSelected() {
        guard entries.indices.contains(selected) else { return }
        scrollToVisible(tileRect(selected).insetBy(dx: 0, dy: -Self.inset))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !entries.isEmpty else { return }
        let h = tileHeight
        let first = max(0, Int((dirtyRect.minY - Self.inset) / h))
        let last = min(rowCount - 1, Int((dirtyRect.maxY - Self.inset) / h))
        guard first <= last else { return }
        for row in first...last {
            for col in 0..<columns {
                let i = row * columns + col
                guard entries.indices.contains(i) else { break }
                let tile = tileRect(i).insetBy(dx: 3, dy: 3)
                if i == selected {
                    let path = NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10)
                    (theme.selection ?? theme.accent.withAlphaComponent(0.22)).setFill()
                    path.fill()
                    theme.accent.withAlphaComponent(0.7).setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
                drawIcon(entries[i], in: tile.insetBy(dx: tile.width * 0.2, dy: tile.height * 0.2))
            }
        }
    }

    private func drawIcon(_ entry: PluginService.Entry, in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let square = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        if let img = image(entry) {
            // Aspect-fit, with rounded corners for photos.
            let s = img.size.width > 0 && img.size.height > 0 ? img.size : NSSize(width: 1, height: 1)
            let scale = min(square.width / s.width, square.height / s.height)
            let fit = NSRect(x: square.midX - s.width * scale / 2, y: square.midY - s.height * scale / 2,
                             width: s.width * scale, height: s.height * scale)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: fit, xRadius: 6, yRadius: 6).addClip()
            img.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let name = entry.item.icon ?? "puzzlepiece.extension"
        let config = NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .regular)
            .applying(.init(paletteColors: [theme.subtext]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return }
        let s = symbol.size
        symbol.draw(in: NSRect(x: square.midX - s.width / 2, y: square.midY - s.height / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func index(at point: NSPoint) -> Int? {
        let col = Int((point.x - Self.inset) / tileWidth), row = Int((point.y - Self.inset) / tileHeight)
        guard point.x >= Self.inset, point.y >= Self.inset, col < columns else { return nil }
        let i = row * columns + col
        return entries.indices.contains(i) ? i : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        selected = i
        onSelect?(i)
        if event.clickCount == 2 { onActivate?(i) }
    }

    override var acceptsFirstResponder: Bool { false } // typing stays in the search field
}
