import Foundation
import EuclidCore
import os

/// Full-text search of visited pages and Obsidian notes, through a local SQLite
/// FTS5 index. Queries run off the main thread and answer like Spotlight files do;
/// pages are downloaded and notes re-read in the background.
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
    private var pagesEnabled = false
    private var pagesLimit = 500
    private var excludedHosts: [String] = []
    private var fetching = false
    private let log = Logger(subsystem: "dev.euclid", category: "content")

    init(databaseURL: URL) {
        do { index = try ContentIndex(path: databaseURL.path) } catch {
            Logger(subsystem: "dev.euclid", category: "content").error("content index unavailable: \(error.localizedDescription, privacy: .public)")
            index = nil
        }
    }

    var isEnabled: Bool { index != nil && (vault != nil || pagesEnabled) }

    func configure(vault path: String?, pagesEnabled: Bool, pagesLimit: Int, excludedHosts: [String]) {
        let newVault = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let vaultChanged = newVault != vault
        vault = newVault
        self.pagesEnabled = pagesEnabled
        self.pagesLimit = pagesLimit
        self.excludedHosts = excludedHosts
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

    /// Download and index recent history pages that aren't indexed yet.
    /// No cookies are sent, so only public pages come back, and links that look
    /// like logins, resets or carry query strings are never fetched (`PageText.shouldFetch`).
    func indexPages(from entries: [HistoryEntry]) {
        guard let index, pagesEnabled, !fetching else { return }
        let excluded = excludedHosts
        let candidates = entries.prefix(pagesLimit).filter { PageText.shouldFetch($0.url, excludedHosts: excluded) }
        guard !candidates.isEmpty else { return }
        fetching = true
        let log = log
        Task.detached(priority: .utility) {
            let done = (try? index.fetchedURLs()) ?? []
            let todo = candidates.filter { !done.contains($0.url) }
            let session = URLSession(configuration: Self.sessionConfiguration)
            var indexed = 0
            // A few at a time: polite to servers, light on the Mac.
            for batch in stride(from: 0, to: todo.count, by: 4).map({ Array(todo[$0..<min($0 + 4, todo.count)]) }) {
                await withTaskGroup(of: (HistoryEntry, (title: String, text: String)?).self) { group in
                    for entry in batch {
                        group.addTask { (entry, await Self.fetchText(entry.url, session: session)) }
                    }
                    for await (entry, page) in group {
                        let title = page?.title.isEmpty == false ? page!.title : entry.title
                        try? index.savePage(url: entry.url, title: title, text: page?.text)
                        if page != nil { indexed += 1 }
                    }
                }
            }
            log.notice("pages: indexed \(indexed) of \(todo.count) new")
            await MainActor.run { self.fetching = false }
        }
    }

    nonisolated private static var sessionConfiguration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 10
        c.httpAdditionalHeaders = ["Accept": "text/html"]
        return c
    }

    /// HTML pages only, up to 2 MB.
    nonisolated private static func fetchText(_ url: String, session: URLSession) async -> (title: String, text: String)? {
        guard let u = URL(string: url), let result = try? await session.data(from: u) else { return nil }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html"), data.count <= 2_000_000 else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        let page = PageText.extract(html: html)
        return page.text.isEmpty ? nil : page
    }
}
