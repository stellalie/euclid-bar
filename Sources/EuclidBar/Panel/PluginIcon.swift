import AppKit
import UniformTypeIdentifiers

/// A plugin item's `icon` that isn't an SF Symbol: an image file (absolute, `~/…`, or relative to
/// the plugin's folder) or an emoji, drawn as an image. Symbols return nil: the cell draws those itself.
@MainActor
enum PluginIcon {
    private enum Kind { case symbol, file(String), text }
    private static var kinds: [String: Kind] = [:]
    private static var images: [String: NSImage] = [:]

    static func image(_ icon: String?, directory: String?) -> NSImage? {
        guard let icon, !icon.isEmpty else { return nil }
        let key = icon + "\u{0}" + (directory ?? "")
        let kind = kinds[key] ?? {
            let k = classify(icon, directory: directory)
            kinds[key] = k
            return k
        }()
        switch kind {
        case .symbol: return nil
        case .file(let path):
            if let cached = images[path] { return cached }
            // An app bundle (`/Applications/Safari.app`) shows the app's own icon, or a plain app
            // icon when it isn't there (an app that moved), never an empty tile.
            let image: NSImage
            if path.hasSuffix(".app") {
                image = FileManager.default.fileExists(atPath: path)
                    ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: .applicationBundle)
            } else {
                guard let file = NSImage(contentsOfFile: path) else { return nil }
                image = file
            }
            if images.count > 500 { images.removeAll() }
            images[path] = image
            return image
        case .text:
            if let cached = images[key] { return cached }
            let image = text(icon)
            images[key] = image
            return image
        }
    }

    /// Whether `icon` is a symbol name (or nothing we can draw), so callers can fall back to a symbol.
    static func isSymbol(_ icon: String?, directory: String?) -> Bool { image(icon, directory: directory) == nil }

    private static func classify(_ icon: String, directory: String?) -> Kind {
        let expanded = (icon as NSString).expandingTildeInPath
        let ext = (icon as NSString).pathExtension.lowercased()
        if expanded.hasPrefix("/") { return .file(expanded) }
        if ["png", "jpg", "jpeg", "gif", "icns", "tif", "tiff", "pdf", "heic", "webp"].contains(ext), let directory {
            return .file((directory as NSString).appendingPathComponent(icon))
        }
        if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil { return .symbol }
        // Not a symbol: an emoji or a short glyph, drawn as text. Longer text is a typo'd symbol name.
        return icon.count <= 3 ? .text : .symbol
    }

    /// Drawn at whatever size it's shown, so it stays sharp.
    private static func text(_ glyph: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: rect.height * 0.78)
            let s = NSAttributedString(string: glyph, attributes: [.font: font])
            let size = s.size()
            s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        return image
    }
}
