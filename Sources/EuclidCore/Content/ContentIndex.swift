import Foundation
import GRDB

/// One full-text hit: a visited page or an Obsidian note.
public struct ContentHit: Sendable, Equatable {
    public enum Kind: String, Sendable { case page, note }
    public let kind: Kind
    /// URL for a page, file path for a note.
    public let ref: String
    public let title: String
    /// A few words around the match, with "…" where text was cut.
    public let snippet: String

    public init(kind: Kind, ref: String, title: String, snippet: String) {
        self.kind = kind
        self.ref = ref
        self.title = title
        self.snippet = snippet
    }
}

/// Local SQLite FTS5 index of page and note text. Searched off the main thread;
/// results arrive after the instant sources, like Spotlight files.
public final class ContentIndex: @unchecked Sendable {
    private let db: DatabaseQueue

    /// `path == nil` opens an in-memory database (tests).
    public init(path: String?) throws {
        if let path {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            var config = Configuration()
            config.journalMode = .wal
            db = try DatabaseQueue(path: path, configuration: config)
        } else {
            db = try DatabaseQueue()
        }
        var m = DatabaseMigrator()
        m.registerMigration("v1_content") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE content USING fts5(kind UNINDEXED, ref UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2');
                CREATE TABLE pages_meta (url TEXT PRIMARY KEY, fetched_at DOUBLE NOT NULL, ok INTEGER NOT NULL);
                CREATE TABLE notes_meta (path TEXT PRIMARY KEY, mtime DOUBLE NOT NULL);
                """)
        }
        try m.migrate(db)
    }

    // MARK: - Search

    /// Every word must appear (as a prefix); title matches rank first.
    public func search(_ query: String, limit: Int = 8) throws -> [ContentHit] {
        guard let match = Self.matchExpression(query) else { return [] }
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT kind, ref, title, snippet(content, 3, '', '', '…', 12) AS snip
                FROM content WHERE content MATCH ? ORDER BY bm25(content, 0, 0, 10.0, 1.0) LIMIT ?
                """, arguments: [match, limit]).map { row in
                ContentHit(kind: ContentHit.Kind(rawValue: row["kind"]) ?? .page, ref: row["ref"], title: row["title"],
                           snippet: (row["snip"] as String? ?? "").replacingOccurrences(of: "\n", with: " "))
            }
        }
    }

    /// "swift test" → `"swift"* "test"*`. Quotes keep FTS syntax in what you type inert.
    static func matchExpression(_ query: String) -> String? {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !words.isEmpty, words.joined().count >= 3 else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Full stored text, for the preview pane.
    public func body(ref: String) -> String? {
        try? db.read { db in try String.fetchOne(db, sql: "SELECT body FROM content WHERE ref = ? LIMIT 1", arguments: [ref]) }
    }

    // MARK: - Pages

    public func fetchedURLs() throws -> Set<String> {
        try db.read { db in Set(try String.fetchAll(db, sql: "SELECT url FROM pages_meta")) }
    }

    /// `text == nil` records a failed fetch, so it isn't retried every time.
    public func savePage(url: String, title: String, text: String?, at now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM content WHERE kind = 'page' AND ref = ?", arguments: [url])
            if let text, !text.isEmpty {
                try db.execute(sql: "INSERT INTO content (kind, ref, title, body) VALUES ('page', ?, ?, ?)", arguments: [url, title, text])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO pages_meta (url, fetched_at, ok) VALUES (?, ?, ?)",
                           arguments: [url, now.timeIntervalSince1970, text != nil])
        }
    }

    // MARK: - Notes

    /// Bring the index in line with the vault: new and changed `.md` files are
    /// (re)read, deleted ones dropped. Returns how many notes were (re)indexed.
    @discardableResult
    public func syncNotes(vault: URL) throws -> Int {
        let fm = FileManager.default
        var onDisk: [String: Double] = [:]
        if let walker = fm.enumerator(at: vault, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                if url.lastPathComponent == ".trash" { walker.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "md",
                      let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      v.isRegularFile == true else { continue }
                onDisk[url.path] = v.contentModificationDate?.timeIntervalSince1970 ?? 0
            }
        }
        let known = try db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT path, mtime FROM notes_meta").map {
                ($0["path"] as String, $0["mtime"] as Double)
            })
        }
        let changed = onDisk.filter { known[$0.key] != $0.value }
        let removed = Set(known.keys).subtracting(onDisk.keys)
        guard !changed.isEmpty || !removed.isEmpty else { return 0 }
        try db.write { db in
            for path in removed {
                try db.execute(sql: "DELETE FROM content WHERE kind = 'note' AND ref = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM notes_meta WHERE path = ?", arguments: [path])
            }
            for (path, mtime) in changed {
                let data = (try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)).readData(ofLength: 200_000)) ?? Data()
                let body = String(decoding: data, as: UTF8.self)
                let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                try db.execute(sql: "DELETE FROM content WHERE kind = 'note' AND ref = ?", arguments: [path])
                try db.execute(sql: "INSERT INTO content (kind, ref, title, body) VALUES ('note', ?, ?, ?)", arguments: [path, title, body])
                try db.execute(sql: "INSERT OR REPLACE INTO notes_meta (path, mtime) VALUES (?, ?)", arguments: [path, mtime])
            }
        }
        return changed.count
    }

    /// Forget a vault that's no longer configured.
    public func removeAllNotes() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM content WHERE kind = 'note'")
            try db.execute(sql: "DELETE FROM notes_meta")
        }
    }
}
