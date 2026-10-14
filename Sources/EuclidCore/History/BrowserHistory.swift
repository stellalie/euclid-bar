import Foundation
import GRDB

/// One visited page, from any browser.
public struct HistoryEntry: Sendable, Equatable {
    public let url: String
    public let title: String
    public let browser: String
    public let lastVisit: Date
    public let visitCount: Int

    public init(url: String, title: String, browser: String, lastVisit: Date, visitCount: Int) {
        self.url = url
        self.title = title
        self.browser = browser
        self.lastVisit = lastVisit
        self.visitCount = visitCount
    }

    public var host: String { URL(string: url)?.host() ?? "" }

    /// Search covers the title and the URL (minus the scheme), so both "pull request" and "github.com/…" match.
    public func searchItem(id: Int) -> SearchItem {
        let shortURL = url.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
        let shown = title.isEmpty ? shortURL : title
        return SearchItem(id: id, title: shown, subtitle: "\(browser) · \(host)", date: lastVisit,
                          searchText: "\(shown) \(shortURL)")
    }
}

/// Reads browser history databases. Browsers keep them locked while running, so
/// each read copies the file (and its WAL) to a temp dir and opens the copy read-only.
public enum BrowserHistory {
    public struct Source: Sendable, Equatable {
        public enum Kind: Sendable { case chromium, safari }
        public let browser: String   // display name, e.g. "Dia"
        public let key: String       // config name, e.g. "dia"
        public let kind: Kind
        public let database: URL
    }

    /// Chromium-family browsers: config key, display name, "User Data" root (relative to Application Support).
    static let chromiumBrowsers: [(key: String, name: String, root: String)] = [
        ("dia", "Dia", "Dia/User Data"),
        ("arc", "Arc", "Arc/User Data"),
        ("chrome", "Chrome", "Google/Chrome"),
        ("brave", "Brave", "BraveSoftware/Brave-Browser"),
        ("edge", "Edge", "Microsoft Edge"),
        ("vivaldi", "Vivaldi", "Vivaldi"),
        ("chromium", "Chromium", "Chromium"),
    ]

    public static let knownKeys: Set<String> = Set(chromiumBrowsers.map(\.key) + ["safari"])

    /// Every history database that exists on this Mac (all Chromium profiles, plus Safari).
    public static func discoverSources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Source] {
        let fm = FileManager.default
        let support = home.appendingPathComponent("Library/Application Support")
        var sources: [Source] = []
        for b in chromiumBrowsers {
            let root = support.appendingPathComponent(b.root)
            let profiles = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                .sorted()
            for profile in profiles {
                let db = root.appendingPathComponent(profile).appendingPathComponent("History")
                if fm.fileExists(atPath: db.path) {
                    sources.append(Source(browser: b.name, key: b.key, kind: .chromium, database: db))
                }
            }
        }
        let safari = home.appendingPathComponent("Library/Safari/History.db")
        if fm.fileExists(atPath: safari.path) {
            sources.append(Source(browser: "Safari", key: "safari", kind: .safari, database: safari))
        }
        return sources
    }

    /// Load the most recent pages from all sources, deduplicated by URL (latest visit wins).
    /// Returns entries newest first, plus per-source errors (e.g. Safari without Full Disk Access).
    public static func load(_ sources: [Source], limit: Int) -> (entries: [HistoryEntry], errors: [(Source, Error)]) {
        var byURL: [String: HistoryEntry] = [:]
        var errors: [(Source, Error)] = []
        for source in sources {
            do {
                for e in try load(source, limit: limit) {
                    if let existing = byURL[e.url], existing.lastVisit >= e.lastVisit { continue }
                    byURL[e.url] = e
                }
            } catch {
                errors.append((source, error))
            }
        }
        let entries = byURL.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(limit)
        return (Array(entries), errors)
    }

    public static func load(_ source: Source, limit: Int) throws -> [HistoryEntry] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("History.db")
        try FileManager.default.copyItem(at: source.database, to: copy)
        for suffix in ["-wal", "-shm"] { // include uncheckpointed writes, if any
            let side = URL(fileURLWithPath: source.database.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: copy.path, configuration: config)
        return try db.read { db in
            switch source.kind {
            case .chromium: try chromiumRows(db, browser: source.browser, limit: limit)
            case .safari: try safariRows(db, limit: limit)
            }
        }
    }

    /// Chromium stores times as microseconds since 1601-01-01 UTC.
    static func chromiumDate(_ micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }

    static func chromiumRows(_ db: Database, browser: String, limit: Int) throws -> [HistoryEntry] {
        try Row.fetchAll(db, sql: """
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
            ORDER BY last_visit_time DESC LIMIT ?
            """, arguments: [limit]).map { row in
            HistoryEntry(url: row["url"], title: (row["title"] as String?) ?? "", browser: browser,
                         lastVisit: chromiumDate(row["last_visit_time"]), visitCount: row["visit_count"])
        }
    }

    /// Safari stores times as seconds since 2001-01-01 UTC; titles live on visits.
    static func safariRows(_ db: Database, limit: Int) throws -> [HistoryEntry] {
        try Row.fetchAll(db, sql: """
            SELECT i.url AS url, i.visit_count AS visit_count, MAX(v.visit_time) AS t,
                   (SELECT title FROM history_visits WHERE history_item = i.id AND title IS NOT NULL
                    ORDER BY visit_time DESC LIMIT 1) AS title
            FROM history_items i JOIN history_visits v ON v.history_item = i.id
            WHERE i.url LIKE 'http://%' OR i.url LIKE 'https://%'
            GROUP BY i.id ORDER BY t DESC LIMIT ?
            """, arguments: [limit]).map { row in
            HistoryEntry(url: row["url"], title: (row["title"] as String?) ?? "", browser: "Safari",
                         lastVisit: Date(timeIntervalSinceReferenceDate: row["t"]), visitCount: row["visit_count"])
        }
    }
}
