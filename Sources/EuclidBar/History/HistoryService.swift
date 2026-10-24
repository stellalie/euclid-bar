import AppKit
import EuclidCore
import os

/// Browser history for search. Loaded off the main thread at launch and
/// refreshed when the panel opens if older than a minute, so it never sits
/// on the typing path.
@MainActor
final class HistoryService {
    private(set) var items: [SearchItem] = []
    private(set) var entries: [HistoryEntry] = []
    /// Site icons by lowercased host (PNG bytes until first drawn).
    private var faviconData: [String: Data] = [:]
    private var faviconImages: [String: NSImage] = [:]
    /// One-line problem for the footer (e.g. Safari needs Full Disk Access), or nil.
    private(set) var problem: String?
    var onChange: (() -> Void)?

    private var enabled = true
    private var browsers: Set<String>?
    private var limit = 5_000
    private var lastLoad: ContinuousClock.Instant?
    private var loading = false
    private let log = Logger(subsystem: "dev.euclid", category: "history")

    func entry(id: Int) -> HistoryEntry? { entries.indices.contains(id) ? entries[id] : nil }

    func favicon(host: String) -> NSImage? {
        if let image = faviconImages[host] { return image }
        guard let data = faviconData[host], let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        faviconImages[host] = image
        return image
    }

    func configure(enabled: Bool, browsers: Set<String>?, limit: Int) {
        let changed = enabled != self.enabled || browsers != self.browsers || limit != self.limit
        self.enabled = enabled
        self.browsers = browsers
        self.limit = limit
        if changed || lastLoad == nil { reload() }
    }

    /// Called when the panel opens.
    func refreshIfStale() {
        guard let last = lastLoad, ContinuousClock.now - last > .seconds(60) else { return }
        reload()
    }

    func reload() {
        guard enabled else {
            entries = []; items = []; faviconData = [:]; faviconImages = [:]; problem = nil; lastLoad = .now
            onChange?()
            return
        }
        guard !loading else { return }
        loading = true
        let browsers = browsers, limit = limit
        DispatchQueue.global(qos: .utility).async {
            let start = ContinuousClock.now
            let sources = BrowserHistory.discoverSources().filter { browsers?.contains($0.key) ?? true }
            let (entries, errors) = BrowserHistory.load(sources, limit: limit)
            let items = entries.enumerated().map { $0.element.searchItem(id: $0.offset) }
            let favicons = BrowserHistory.favicons(for: sources, hosts: Set(entries.map { $0.host.lowercased() }))
            // Safari is protected by Full Disk Access; only complain if it was asked for explicitly.
            let failed = errors.map(\.0.browser).filter { browsers != nil || $0 != "Safari" }
            let elapsed = ContinuousClock.now - start
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.entries = entries
                    self.items = items
                    self.faviconData = favicons
                    self.faviconImages = [:]
                    self.problem = failed.contains("Safari")
                        ? "⚠︎ Safari history needs Full Disk Access (System Settings › Privacy & Security)"
                        : failed.isEmpty ? nil : "⚠︎ couldn't read history: \(failed.joined(separator: ", "))"
                    self.lastLoad = .now
                    self.loading = false
                    self.log.notice("history: \(entries.count) pages, \(favicons.count) icons from \(sources.count) sources in \(String(describing: elapsed), privacy: .public)")
                    self.onChange?()
                }
            }
        }
    }
}
