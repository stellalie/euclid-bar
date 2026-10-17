import Foundation
import GRDB

/// Learns which result you pick for what you type (Raycast-style "frecency").
///
/// Every pick is remembered as (query, item key). A result earns a bonus when you
/// picked it for the same query, or for a query that one extends ("saf" counts for
/// "sa" and "safar"), weighted by how often and how recently. Items you use a lot
/// get a small bonus for any query. In memory and O(picks) per keystroke; a few
/// thousand picks cost microseconds.
public struct Frecency: Sendable {
    public struct Pick: Sendable, Equatable {
        public let query: String
        public let key: String
        public var count: Int
        public var last: Date

        public init(query: String, key: String, count: Int, last: Date) {
            self.query = query
            self.key = key
            self.count = count
            self.last = last
        }
    }

    /// Picks older than this count half as much.
    public static let halfLife: TimeInterval = 14 * 86_400
    /// Cap so a learned pick can beat a better text match, but never a much better one.
    public static let maxBonus = 600
    /// Oldest picks are forgotten past this.
    public static let limit = 3_000

    public private(set) var picks: [Pick] = []
    private var index: [String: Int] = [:] // "query\u{0}key" → position in picks

    public init(_ picks: [Pick] = []) {
        for p in picks.sorted(by: { $0.last > $1.last }).prefix(Self.limit) { append(p) }
    }

    public static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Remember a pick. Returns the updated row so a store can persist it.
    @discardableResult
    public mutating func record(query: String, key: String, at now: Date = Date()) -> Pick {
        let q = Self.normalize(query)
        let id = q + "\u{0}" + key
        if let i = index[id] {
            picks[i].count += 1
            picks[i].last = now
            return picks[i]
        }
        let pick = Pick(query: q, key: key, count: 1, last: now)
        append(pick)
        if picks.count > Self.limit { self = Frecency(picks) } // drop the oldest
        return pick
    }

    public mutating func forget(key: String) {
        self = Frecency(picks.filter { $0.key != key })
    }

    /// Bonus for every item that was ever picked for something related to `query`.
    public func bonuses(for query: String, now: Date = Date()) -> [String: Int] {
        let q = Self.normalize(query)
        var weight: [String: Double] = [:]
        for p in picks {
            let w = Double(p.count) * pow(0.5, max(0, now.timeIntervalSince(p.last)) / Self.halfLife)
            let factor: Double
            if q.isEmpty || p.query == q { factor = 1 }
            else if p.query.hasPrefix(q) || (!p.query.isEmpty && q.hasPrefix(p.query)) { factor = 0.5 }
            else { factor = 0.1 }
            weight[p.key, default: 0] += w * factor
        }
        return weight.mapValues { min(Self.maxBonus, Int(250 * log2(1 + $0))) }.filter { $0.value > 0 }
    }

    /// Most used items overall, best first (for the empty search box).
    public func top(_ n: Int, now: Date = Date()) -> [String] {
        bonuses(for: "", now: now).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(n).map(\.key)
    }

    private mutating func append(_ p: Pick) {
        index[p.query + "\u{0}" + p.key] = picks.count
        picks.append(p)
    }
}

/// SQLite persistence for picks, in its own file next to clipboard history.
/// Read once at launch; written in the background after each pick.
public final class FrecencyStore: Sendable {
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
        m.registerMigration("v1_picks") { db in
            try db.create(table: "picks") { t in
                t.column("query", .text).notNull()
                t.column("key", .text).notNull()
                t.column("count", .integer).notNull()
                t.column("last", .double).notNull()
                t.primaryKey(["query", "key"])
            }
        }
        try m.migrate(db)
    }

    public func load() throws -> Frecency {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM picks ORDER BY last DESC LIMIT ?",
                                        arguments: [Frecency.limit])
            return Frecency(rows.map {
                Frecency.Pick(query: $0["query"], key: $0["key"], count: $0["count"],
                              last: Date(timeIntervalSince1970: $0["last"]))
            })
        }
    }

    public func save(_ pick: Frecency.Pick) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO picks (query, key, count, last) VALUES (?, ?, ?, ?)
                ON CONFLICT(query, key) DO UPDATE SET count = excluded.count, last = excluded.last
                """, arguments: [pick.query, pick.key, pick.count, pick.last.timeIntervalSince1970])
            // Keep the file as small as the in-memory model.
            try db.execute(sql: """
                DELETE FROM picks WHERE rowid NOT IN (SELECT rowid FROM picks ORDER BY last DESC LIMIT ?)
                """, arguments: [Frecency.limit])
        }
    }

    public func forget(key: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM picks WHERE key = ?", arguments: [key]) }
    }
}
