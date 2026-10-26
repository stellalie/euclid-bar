import Foundation
import EuclidCore
import os

/// Full-text search of Obsidian notes, through a local SQLite FTS5 index. Queries run
/// off the main thread and answer like Spotlight files do; notes are re-read in the background.
@MainActor
final class ContentService {
    /// Called with results for the query they belong to.
    var onResults: ((_ query: String, [ContentHit]) -> Void)?

    private let index: ContentIndex?
    private let queue = DispatchQueue(label: "dev.euclid.content", qos: .userInitiated)
    private let indexQueue = DispatchQueue(label: "dev.euclid.content-index", qos: .utility)
    private var pending: DispatchWorkItem?
    private var currentText = ""
    private var vault: URL?
    private var lastNotesSync: ContinuousClock.Instant?
    private let log = Logger(subsystem: "dev.euclid", category: "content")

    init(databaseURL: URL) {
        do { index = try ContentIndex(path: databaseURL.path) } catch {
            Logger(subsystem: "dev.euclid", category: "content").error("content index unavailable: \(error.localizedDescription, privacy: .public)")
            index = nil
        }
    }

    var isEnabled: Bool { index != nil && vault != nil }

    func configure(vault path: String?) {
        let newVault = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let vaultChanged = newVault != vault
        vault = newVault
        if vaultChanged {
            lastNotesSync = nil
            if let index, newVault == nil { indexQueue.async { try? index.removeAllNotes() } }
            syncNotesIfStale()
        }
    }

    // MARK: - Search

    func search(_ text: String) {
        pending?.cancel()
        currentText = text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let index, isEnabled, trimmed.count >= 3, Calculator.evaluate(trimmed) == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.start(trimmed, for: text, index: index) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work) // wait for a pause in typing
    }

    private func start(_ trimmed: String, for text: String, index: ContentIndex) {
        queue.async { [log] in
            let started = ContinuousClock.now
            let hits = (try? index.search(trimmed, limit: 6)) ?? []
            let elapsed = ContinuousClock.now - started
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard text == self.currentText else { return }
                    log.notice("content: \(hits.count) hits in \(String(describing: elapsed), privacy: .public)")
                    self.onResults?(text, hits)
                }
            }
        }
    }

    func body(ref: String) -> String? { index?.body(ref: ref) }

    // MARK: - Indexing

    /// Re-read changed notes when the panel opens, at most every two minutes.
    func syncNotesIfStale() {
        guard let index, let vault else { return }
        if let last = lastNotesSync, ContinuousClock.now - last < .seconds(120) { return }
        lastNotesSync = .now
        indexQueue.async { [log] in
            let start = ContinuousClock.now
            do {
                let n = try index.syncNotes(vault: vault)
                log.notice("notes: \(n) (re)indexed in \(String(describing: ContinuousClock.now - start), privacy: .public)")
            } catch {
                log.error("notes: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
