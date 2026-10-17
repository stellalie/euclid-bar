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

    private struct Box: @unchecked Sendable { let image: NSImage }

    init() { cache.countLimit = 500 }

    func icon(forPath path: String) -> NSImage? {
        if let image = cache.object(forKey: path as NSString) { return image }
        guard pending.insert(path).inserted else { return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: 32, height: 32)
            let box = Box(image: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.cache.setObject(box.image, forKey: path as NSString)
                    self.pending.remove(path)
                    self.onLoad?(path)
                }
            }
        }
        return nil
    }
}
