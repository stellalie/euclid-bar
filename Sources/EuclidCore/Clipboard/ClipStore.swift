import Foundation
import GRDB

/// SQLite persistence for clipboard history. Never on the typing path:
/// read once at launch, then written asynchronously (in order) after each change.
public final class ClipStore: Sendable {
    private let db: DatabaseQueue

    /// `path == nil` opens an in-memory database (tests).
    public init(path: String?) throws {
        if let path {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            var config = Configuration()
            config.journalMode = .wal // background writes never block reads
            db = try DatabaseQueue(path: path, configuration: config)
        } else {
            db = try DatabaseQueue()
        }
        try migrator.migrate(db)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_clips") { db in
            try db.create(table: "clips") { t in
                t.primaryKey("id", .integer)
                t.column("content", .text).notNull()
                t.column("source_bundle_id", .text)
                t.column("source_name", .text)
                t.column("created_at", .double).notNull()
                t.column("last_used_at", .double).notNull()
                t.column("use_count", .integer).notNull().defaults(to: 1)
            }
            try db.create(index: "clips_last_used", on: "clips", columns: ["last_used_at"])
        }
        return m
    }

    public func loadRecent(limit: Int) throws -> [Clip] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM clips ORDER BY last_used_at DESC LIMIT ?
                """, arguments: [limit]).map { row in
                Clip(
                    id: row["id"], content: row["content"],
                    sourceBundleID: row["source_bundle_id"], sourceName: row["source_name"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    lastUsedAt: Date(timeIntervalSince1970: row["last_used_at"]),
                    useCount: row["use_count"]
                )
            }
        }
    }

    /// Enqueue a change. Writes run serially, in call order, off the main thread.
    public func apply(_ change: ClipHistory.Change, completion: (@Sendable (Error?) -> Void)? = nil) {
        db.asyncWrite({ db in try Self.write(change, db) }, completion: { _, result in
            if case .failure(let error) = result { completion?(error) } else { completion?(nil) }
        })
    }

    /// Synchronous variant (tests, shutdown).
    public func applySync(_ change: ClipHistory.Change) throws {
        try db.write { db in try Self.write(change, db) }
    }

    private static func write(_ change: ClipHistory.Change, _ db: Database) throws {
        if let c = change.saved {
            try db.execute(sql: """
                INSERT INTO clips (id, content, source_bundle_id, source_name, created_at, last_used_at, use_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_bundle_id = excluded.source_bundle_id,
                    source_name = excluded.source_name,
                    last_used_at = excluded.last_used_at,
                    use_count = excluded.use_count
                """, arguments: [c.id, c.content, c.sourceBundleID, c.sourceName,
                                 c.createdAt.timeIntervalSince1970, c.lastUsedAt.timeIntervalSince1970, c.useCount])
        }
        for id in change.deletedIDs {
            try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [id])
        }
    }
}
