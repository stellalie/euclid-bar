import Foundation
import GRDB
import Testing
@testable import EuclidCore

@Suite struct BrowserHistoryTests {
    /// Builds a fake home with a Chromium-style (Dia) profile and a Safari database.
    func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dia = home.appendingPathComponent("Library/Application Support/Dia/User Data")
        for profile in ["Default", "Profile 1"] {
            let dir = dia.appendingPathComponent(profile)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let db = try DatabaseQueue(path: dir.appendingPathComponent("History").path)
            try db.write { db in
                try db.execute(sql: """
                    CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER NOT NULL DEFAULT 0,
                                      typed_count INTEGER NOT NULL DEFAULT 0, last_visit_time INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0)
                    """)
                // 2026-01-01T00:00:00Z in Chromium time = (unix + 11644473600) * 1e6
                let base: Int64 = (1_767_225_600 + 11_644_473_600) * 1_000_000
                let rows: [(String, String, Int64, Int)] = profile == "Default" ? [
                    ("https://github.com/stellalie/euclid-bar/pull/1", "Add browser history by stellalie · Pull Request #1", base + 30_000_000, 0),
                    ("https://docs.swift.org/swift-book/", "The Swift Programming Language", base, 0),
                    ("chrome://settings", "Settings", base, 0),             // not http(s): skipped
                    ("https://hidden.example.com", "Hidden", base, 1),       // hidden: skipped
                ] : [
                    ("https://docs.swift.org/swift-book/", "The Swift Programming Language", base + 120_000_000, 0), // newer dup
                ]
                for r in rows {
                    try db.execute(sql: "INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES (?, ?, 3, ?, ?)",
                                   arguments: [r.0, r.1, r.2, r.3])
                }
            }
        }
        let safariDir = home.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: safariDir, withIntermediateDirectories: true)
        let safari = try DatabaseQueue(path: safariDir.appendingPathComponent("History.db").path)
        try safari.write { db in
            try db.execute(sql: """
                CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);
                CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
                INSERT INTO history_items VALUES (1, 'https://www.apple.com/macos/', 2);
                INSERT INTO history_visits VALUES (1, 1, 788918400.0, 'macOS - Apple');
                INSERT INTO history_visits VALUES (2, 1, 788918460.0, NULL);
                """)
        }
        return home
    }

    @Test func discoversProfilesAndSafari() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sources = BrowserHistory.discoverSources(home: home)
        #expect(sources.map(\.browser) == ["Dia", "Dia", "Safari"])
    }

    @Test func loadsDedupesAndConvertsTimes() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (entries, errors) = BrowserHistory.load(BrowserHistory.discoverSources(home: home), limit: 100)
        #expect(errors.isEmpty)
        // Newest first: swift.org 00:02 (Profile 1's newer visit wins the dedupe),
        // apple.com 00:01 (Safari), github.com 00:00:30.
        #expect(entries.map(\.url) == [
            "https://docs.swift.org/swift-book/",
            "https://www.apple.com/macos/",
            "https://github.com/stellalie/euclid-bar/pull/1",
        ])
        let swift = try #require(entries.first { $0.url.contains("swift.org") })
        #expect(swift.lastVisit == Date(timeIntervalSince1970: 1_767_225_600 + 120))
        let apple = try #require(entries.first { $0.browser == "Safari" })
        #expect(apple.title == "macOS - Apple")                  // title from the visit that has one
        #expect(apple.lastVisit == Date(timeIntervalSinceReferenceDate: 788_918_460))
    }

    @Test func searchMatchesTitleOrURL() throws {
        let e = HistoryEntry(url: "https://github.com/stellalie/euclid-bar/pull/1", title: "Add browser history",
                             browser: "Dia", lastVisit: Date(), visitCount: 1)
        let item = e.searchItem(id: 0)
        #expect(item.subtitle == "Dia · github.com")
        #expect(!FuzzyMatcher.search("browser history", in: [item]).isEmpty)
        #expect(!FuzzyMatcher.search("github.com/stella", in: [item]).isEmpty)
    }

    @Test func normalizesURLsForDedupe() {
        let n = BrowserHistory.normalizedURL
        #expect(n("https://www.GitHub.com/stellalie/euclid-bar/") == "github.com/stellalie/euclid-bar")
        #expect(n("http://github.com/stellalie/euclid-bar#readme") == "github.com/stellalie/euclid-bar")
        #expect(n("https://example.com/?utm_source=x&utm_medium=y") == "example.com")
        #expect(n("https://example.com/a?id=1&fbclid=abc") == "example.com/a?id=1")
        #expect(n("https://example.com/search?q=swift") != n("https://example.com/search?q=rust"))
        #expect(n("http://localhost:3000/") == "localhost:3000")
    }

    @Test func dedupesNearDuplicatesKeepingLatestVisit() {
        let t0 = Date(timeIntervalSince1970: 1_767_225_600)
        func e(_ url: String, _ title: String, _ browser: String, _ minutes: Double) -> HistoryEntry {
            HistoryEntry(url: url, title: title, browser: browser, lastVisit: t0 + minutes * 60, visitCount: 2)
        }
        let out = BrowserHistory.dedupe([
            e("https://github.com/stellalie/euclid-bar", "euclid-bar", "Dia", 1),
            e("https://github.com/stellalie/euclid-bar/#readme", "euclid-bar", "Safari", 5),   // same page
            e("https://app.example.com/inbox/123", "Inbox", "Chrome", 2),
            e("https://app.example.com/inbox/456", "Inbox", "Chrome", 3),                    // looks identical
            e("https://news.example.com/", "", "Arc", 4),
            e("https://news.example.com/?utm_source=hn", "", "Arc", 0),                       // tracking only
            e("https://other.example.com/inbox", "Inbox", "Chrome", 1),                        // same title, other site
        ])
        #expect(out.map(\.url) == [
            "https://github.com/stellalie/euclid-bar/#readme",
            "https://news.example.com/",
            "https://app.example.com/inbox/456",
            "https://other.example.com/inbox",
        ])
        #expect(out[0].browser == "Safari")
        #expect(out[0].lastVisit == t0 + 300)
        #expect(out[0].visitCount == 4)
    }

    @Test func shortRelativeAge() {
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        #expect(RelativeAge.short(now - 20, now: now) == "just now")
        #expect(RelativeAge.short(now - 5 * 60, now: now) == "5m ago")
        #expect(RelativeAge.short(now - 2 * 3_600, now: now) == "2h ago")
        #expect(RelativeAge.short(now - 3 * 86_400, now: now) == "3d ago")
        #expect(RelativeAge.short(now - 15 * 86_400, now: now) == "2w ago")
        #expect(RelativeAge.short(now + 30, now: now) == "just now")   // clock skew
    }

    @Test func unreadableSourceIsReportedNotFatal() {
        let bogus = BrowserHistory.Source(browser: "Safari", key: "safari", kind: .safari,
                                          database: URL(fileURLWithPath: "/nonexistent/History.db"))
        let (entries, errors) = BrowserHistory.load([bogus], limit: 10)
        #expect(entries.isEmpty)
        #expect(errors.count == 1)
    }

    @Test func historyConfig() throws {
        let loaded = try ConfigLoader.parse("""
            [history]
            enabled = false
            browsers = ["Dia", "netscape"]
            limit = 200
            """)
        #expect(loaded.config.historyEnabled == false)
        #expect(loaded.config.historyBrowsers == ["dia"])
        #expect(loaded.config.historyLimit == 200)
        #expect(loaded.issues.map(\.message).joined().contains("unknown browser 'netscape'"))
    }
}
