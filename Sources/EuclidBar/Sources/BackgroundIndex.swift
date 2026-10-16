import Foundation
import EuclidCore
import os

/// A list that's slow-ish to build (a directory walk), so it's built off the
/// main thread and only swapped in when ready. Refreshed when the panel opens
/// if older than `maxAge`, so it never sits on the typing path.
@MainActor
final class BackgroundIndex<Entry: Sendable> {
    private(set) var entries: [Entry] = []
    private(set) var items: [SearchItem] = []
    var onChange: (() -> Void)?

    private let name: String
    private let maxAge: Duration
    private let makeItem: @Sendable (Entry, Int) -> SearchItem
    private var scan: (@Sendable () -> [Entry])?
    private var lastLoad: ContinuousClock.Instant?
    private var loading = false
    private var generation = 0
    private let log = Logger(subsystem: "dev.euclid", category: "index")

    init(name: String, maxAge: Duration, makeItem: @escaping @Sendable (Entry, Int) -> SearchItem) {
        self.name = name
        self.maxAge = maxAge
        self.makeItem = makeItem
    }

    func entry(id: Int) -> Entry? { entries.indices.contains(id) ? entries[id] : nil }

    /// New scan settings (from config). `nil` disables the source.
    func configure(_ scan: (@Sendable () -> [Entry])?) {
        self.scan = scan
        generation += 1
        loading = false
        guard scan != nil else {
            entries = []; items = []; lastLoad = nil
            onChange?()
            return
        }
        reload()
    }

    func refreshIfStale() {
        guard let last = lastLoad, ContinuousClock.now - last > maxAge else { return }
        reload()
    }

    func reload() {
        guard let scan, !loading else { return }
        loading = true
        let generation = generation, makeItem = makeItem, name = name
        DispatchQueue.global(qos: .utility).async {
            let start = ContinuousClock.now
            let entries = scan()
            let items = entries.enumerated().map { makeItem($0.element, $0.offset) }
            let elapsed = ContinuousClock.now - start
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else { return } // config changed meanwhile
                    self.entries = entries
                    self.items = items
                    self.lastLoad = .now
                    self.loading = false
                    self.log.notice("\(name, privacy: .public): \(entries.count) in \(String(describing: elapsed), privacy: .public)")
                    self.onChange?()
                }
            }
        }
    }
}
