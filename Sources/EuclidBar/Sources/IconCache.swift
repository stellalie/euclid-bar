import AppKit

/// File and app icons, loaded off the main thread on first use and kept.
/// Rows draw a symbol until the real icon arrives, then get redrawn.
@MainActor
final class IconCache {
    static let shared = IconCache()

    /// Called on the main thread with the path whose icon just loaded.
    var onLoad: ((String) -> Void)?

    private let cache = NSCache<NSString, NSImage>()
    private var pending = Set<String>()
    /// Bundle IDs with no app on this Mac, so they're looked up once.
    private var missing = Set<String>()
    /// Paths whose icon drew nothing, so they keep their symbol and aren't loaded again.
    private var blank = Set<String>()

    private struct Box: @unchecked Sendable { let image: NSImage }

    init() { cache.countLimit = 500 }

    /// Draws `icon` into real pixels now, off the main thread. A workspace icon is lazy: drawn later it
    /// can come out blank (seen in the empty bar's first frame). Nil when it drew nothing at all.
    nonisolated static func rasterized(_ icon: NSImage, side: Int = 64) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        // Any visible pixel? (Check a coarse grid; a real icon covers most of it.)
        var seen = false
        for y in stride(from: 4, to: side, by: 8) where !seen {
            for x in stride(from: 4, to: side, by: 8) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { seen = true; break }
        }
        guard seen else { return nil }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(rep)
        return image
    }

    func icon(forPath path: String) -> NSImage? {
        if let image = cache.object(forKey: path as NSString) { return image }
        guard !blank.contains(path), pending.insert(path).inserted else { return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            let box = Self.rasterized(NSWorkspace.shared.icon(forFile: path)).map(Box.init)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending.remove(path)
                    guard let box else { self.blank.insert(path); return } // the row keeps its symbol
                    self.cache.setObject(box.image, forKey: path as NSString)
                    self.onLoad?(path)
                }
            }
        }
        return nil
    }

    /// An app's icon by bundle ID (a clip's source app), keyed `bundle:<id>` for `onLoad`.
    func icon(forBundleID id: String) -> NSImage? {
        let key = "bundle:\(id)"
        if let image = cache.object(forKey: key as NSString) { return image }
        guard !missing.contains(id), pending.insert(key).inserted else { return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            let box = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .flatMap { Self.rasterized(NSWorkspace.shared.icon(forFile: $0.path)) }.map(Box.init)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending.remove(key)
                    guard let box else { self.missing.insert(id); return }
                    self.cache.setObject(box.image, forKey: key as NSString)
                    self.onLoad?(key)
                }
            }
        }
        return nil
    }
}
