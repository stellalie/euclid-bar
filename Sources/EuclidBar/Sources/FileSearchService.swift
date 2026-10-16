import Foundation
import EuclidCore
import os

/// One file or folder from Spotlight.
struct FileHit: Equatable {
    let path: String
    let isFolder: Bool
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { ProjectScanner.abbreviate((path as NSString).deletingLastPathComponent) }
}

/// File search by name through Spotlight's index (no index of our own to build or keep).
/// Asynchronous: results arrive after the instant sources and are shown below them,
/// so they never push the top rows around while you're pressing ↵.
@MainActor
final class FileSearchService {
    var enabled = true
    var limit = 8
    /// Called with results for the query they belong to.
    var onResults: ((_ query: String, [FileHit]) -> Void)?

    static let minQueryLength = 3

    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var currentText = ""
    private var pending: DispatchWorkItem?
    private let log = Logger(subsystem: "dev.euclid", category: "files")

    /// Paths that are noise for a launcher: app internals, caches, dependencies.
    private static let excluded = ["/Library/", "/node_modules/", "/.", ".app/", "/DerivedData/", "/.build/", "/Pods/"]

    func search(_ text: String) {
        pending?.cancel()
        stop()
        currentText = text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard enabled, trimmed.count >= Self.minQueryLength, Calculator.evaluate(trimmed) == nil else { return }
        // Wait for a pause in typing; every keystroke cancels the previous query.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.start(trimmed, for: text) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func cancel() {
        pending?.cancel()
        stop()
        currentText = ""
    }

    private func start(_ trimmed: String, for text: String) {
        let started = ContinuousClock.now
        let q = NSMetadataQuery()
        // Every word must appear in the name: "readme euclid" finds euclid-bar/README.md's siblings too.
        let words = trimmed.split(separator: " ").map { NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\($0)*") }
        q.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: words)
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(text: text, started: started) }
        }
        query = q
        q.start()
    }

    private func finish(text: String, started: ContinuousClock.Instant) {
        guard let q = query, text == currentText else { return }
        q.disableUpdates()
        var hits: [FileHit] = []
        let n = q.resultCount
        var i = 0
        while i < n, i < 300, hits.count < limit {
            if let item = q.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
               !Self.excluded.contains(where: { path.contains($0) }) {
                let type = item.value(forAttribute: "kMDItemContentType") as? String
                hits.append(FileHit(path: path, isFolder: type == "public.folder"))
            }
            i += 1
        }
        stop()
        log.notice("files: \(hits.count) of \(n) in \(String(describing: ContinuousClock.now - started), privacy: .public)")
        onResults?(text, hits)
    }

    private func stop() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
