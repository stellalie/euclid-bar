import AppKit
import CryptoKit
import EuclidCore
import os

/// Glue: monitor → in-memory history (search) → SQLite (async persistence).
/// Images are stored as PNG files next to the database, named by their hash.
@MainActor
final class ClipboardService {
    let history: ClipHistory
    private let store: ClipStore?
    private let imagesDirectory: URL
    private var monitor: ClipboardMonitor?
    private let thumbnails = NSCache<NSString, NSImage>()
    private let log = Logger(subsystem: "dev.euclid", category: "clipboard")

    /// Called after any change, so a visible panel can refresh its results.
    var onChange: (() -> Void)?
    /// Copies made in these apps are never recorded (from config `clipboard.ignore_apps`).
    var ignoredBundleIDs: Set<String> = []

    /// Bigger images are skipped rather than stored.
    static let maxImageBytes = 25_000_000

    init(databaseURL: URL, imagesDirectory: URL, limit: Int = 5_000) {
        let start = ContinuousClock.now
        var store: ClipStore?
        var existing: [Clip] = []
        do {
            let s = try ClipStore(path: databaseURL.path)
            existing = try s.loadRecent(limit: limit)
            store = s
        } catch {
            // Keep working in memory-only mode rather than failing to launch.
            log.error("history store unavailable: \(error.localizedDescription, privacy: .public)")
        }
        self.store = store
        self.imagesDirectory = imagesDirectory
        thumbnails.countLimit = 200
        history = ClipHistory(limit: limit, loading: existing)
        perfLog.notice("loaded \(self.history.count) clips in \(String(describing: ContinuousClock.now - start), privacy: .public)")
        removeOrphanedImages(keeping: Set(existing.filter { $0.kind == .image }.map(\.content)))
    }

    func start() {
        let monitor = ClipboardMonitor { [weak self] copied, app in
            guard let self else { return }
            if let id = app?.bundleIdentifier, self.ignoredBundleIDs.contains(id) { return }
            let bundle = app?.bundleIdentifier, name = app?.localizedName
            switch copied {
            case .text(let text):
                self.apply(self.history.record(text, sourceBundleID: bundle, sourceName: name))
            case .files(let paths):
                self.apply(self.history.record(paths.joined(separator: "\n"), kind: .files, sourceBundleID: bundle, sourceName: name))
            case .image(let data):
                self.storeImage(data, bundle: bundle, name: name)
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    func markUsed(id: Int) { apply(history.markUsed(id: id)) }

    func delete(id: Int) {
        let clip = history.clip(id: id)
        apply(history.delete(id: id))
        if let clip, clip.kind == .image { try? FileManager.default.removeItem(at: imageURL(clip)) }
    }

    func clearAll() {
        apply(history.removeAll())
        removeOrphanedImages(keeping: [])
    }

    func imageURL(_ clip: Clip) -> URL { imagesDirectory.appendingPathComponent(clip.content) }

    /// The stored image, cached (rows and the preview ask for it repeatedly).
    func image(for clip: Clip) -> NSImage? {
        guard clip.kind == .image else { return nil }
        if let cached = thumbnails.object(forKey: clip.content as NSString) { return cached }
        guard let image = NSImage(contentsOf: imageURL(clip)) else { return nil }
        thumbnails.setObject(image, forKey: clip.content as NSString)
        return image
    }

    /// PNG-encode, hash and write off the main thread, then record.
    private func storeImage(_ data: Data, bundle: String?, name: String?) {
        guard data.count <= Self.maxImageBytes else { return }
        let dir = imagesDirectory
        DispatchQueue.global(qos: .utility).async { [log] in
            guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return }
            let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            let file = dir.appendingPathComponent("\(hash).png")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) { try png.write(to: file, options: .atomic) }
            } catch {
                log.error("can't store image: \(error.localizedDescription, privacy: .public)")
                return
            }
            let size = "\(rep.pixelsWide)×\(rep.pixelsHigh)"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apply(self.history.record(file.lastPathComponent, kind: .image, meta: size, sourceBundleID: bundle, sourceName: name))
                }
            }
        }
    }

    /// Images whose clip was evicted (over the limit) or deleted while we weren't looking.
    private func removeOrphanedImages(keeping: Set<String>) {
        let dir = imagesDirectory
        DispatchQueue.global(qos: .background).async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasSuffix(".png") && !keeping.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    private func apply(_ change: ClipHistory.Change?) {
        guard let change else { return }
        store?.apply(change) { [log] error in
            if let error { log.error("write failed: \(error.localizedDescription, privacy: .public)") }
        }
        onChange?()
    }
}
