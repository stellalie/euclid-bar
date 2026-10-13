import AppKit
import EuclidCore
import os

/// Glue: monitor → in-memory history (search) → SQLite (async persistence).
@MainActor
final class ClipboardService {
    let history: ClipHistory
    private let store: ClipStore?
    private var monitor: ClipboardMonitor?
    private let log = Logger(subsystem: "dev.euclid", category: "clipboard")

    /// Called after any change, so a visible panel can refresh its results.
    var onChange: (() -> Void)?

    init(limit: Int = 5_000) {
        let start = ContinuousClock.now
        var store: ClipStore?
        var existing: [Clip] = []
        do {
            let s = try ClipStore(path: ClipStore.defaultPath)
            existing = try s.loadRecent(limit: limit)
            store = s
        } catch {
            // Keep working in memory-only mode rather than failing to launch.
            log.error("history store unavailable: \(error.localizedDescription, privacy: .public)")
        }
        self.store = store
        history = ClipHistory(limit: limit, loading: existing)
        perfLog.notice("loaded \(self.history.count) clips in \(String(describing: ContinuousClock.now - start), privacy: .public)")
    }

    func start() {
        let monitor = ClipboardMonitor { [weak self] text, app in
            self?.apply(self?.history.record(text, sourceBundleID: app?.bundleIdentifier, sourceName: app?.localizedName))
        }
        monitor.start()
        self.monitor = monitor
    }

    func markUsed(id: Int) { apply(history.markUsed(id: id)) }
    func delete(id: Int) { apply(history.delete(id: id)) }
    func clearAll() { apply(history.removeAll()) }

    private func apply(_ change: ClipHistory.Change?) {
        guard let change else { return }
        store?.apply(change) { [log] error in
            if let error { log.error("write failed: \(error.localizedDescription, privacy: .public)") }
        }
        onChange?()
    }
}
