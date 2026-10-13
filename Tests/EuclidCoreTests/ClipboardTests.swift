import Foundation
import Testing
@testable import EuclidCore

@Suite struct ClipHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func newestFirst() {
        let h = ClipHistory()
        h.record("a", sourceBundleID: nil, sourceName: nil, at: t0)
        h.record("b", sourceBundleID: nil, sourceName: nil, at: t0 + 1)
        #expect(h.items.map(\.title) == ["b", "a"])
    }

    @Test func recopyMovesToTopWithoutDuplicate() throws {
        let h = ClipHistory()
        let first = try #require(h.record("a", sourceBundleID: nil, sourceName: nil, at: t0)?.saved)
        h.record("b", sourceBundleID: nil, sourceName: nil, at: t0 + 1)
        let again = try #require(h.record("a", sourceBundleID: "x", sourceName: "X", at: t0 + 2)?.saved)
        #expect(h.items.map(\.title) == ["a", "b"])
        #expect(again.id == first.id)
        #expect(again.useCount == 2)
        #expect(again.createdAt == t0)
    }

    @Test func ignoresBlankAndHuge() {
        let h = ClipHistory()
        #expect(h.record("  \n\t", sourceBundleID: nil, sourceName: nil) == nil)
        #expect(h.record(String(repeating: "x", count: ClipHistory.maxContentBytes + 1),
                         sourceBundleID: nil, sourceName: nil) == nil)
        #expect(h.count == 0)
    }

    @Test func evictsOldestBeyondLimit() throws {
        let h = ClipHistory(limit: 2)
        let a = try #require(h.record("a", sourceBundleID: nil, sourceName: nil, at: t0)?.saved)
        h.record("b", sourceBundleID: nil, sourceName: nil, at: t0 + 1)
        let change = try #require(h.record("c", sourceBundleID: nil, sourceName: nil, at: t0 + 2))
        #expect(change.deletedIDs == [a.id])
        #expect(h.items.map(\.title) == ["c", "b"])
        // Evicted content is genuinely forgotten, so re-copying creates a fresh entry.
        #expect(h.record("a", sourceBundleID: nil, sourceName: nil, at: t0 + 3)?.saved?.useCount == 1)
    }

    @Test func markUsedAndDelete() throws {
        let h = ClipHistory()
        let a = try #require(h.record("a", sourceBundleID: nil, sourceName: nil, at: t0)?.saved)
        h.record("b", sourceBundleID: nil, sourceName: nil, at: t0 + 1)
        h.markUsed(id: a.id, at: t0 + 2)
        #expect(h.items.map(\.title) == ["a", "b"])
        #expect(h.delete(id: a.id)?.deletedIDs == [a.id])
        #expect(h.items.map(\.title) == ["b"])
        #expect(h.delete(id: a.id) == nil)
    }

    @Test func loadingContinuesIDsAndOrder() {
        let existing = [
            Clip(id: 7, content: "old", createdAt: t0),
            Clip(id: 3, content: "new", createdAt: t0, lastUsedAt: t0 + 5),
        ]
        let h = ClipHistory(loading: existing)
        #expect(h.items.map(\.title) == ["new", "old"])
        #expect(h.record("fresh", sourceBundleID: nil, sourceName: nil)?.saved?.id == 8)
    }
}

@Suite struct ClipStoreTests {
    @Test func roundTripThroughSQLite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("h.sqlite").path
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_000)
        let store = try ClipStore(path: path)
        let h = ClipHistory(limit: 2)
        for (i, s) in ["a", "b", "c"].enumerated() {
            try store.applySync(try #require(h.record(s, sourceBundleID: "com.x", sourceName: "X", at: t0 + Double(i))))
        }
        try store.applySync(try #require(h.markUsed(id: h.items[1].id, at: t0 + 10))) // bump "b"

        // Reopen from disk, as on next launch.
        let reloaded = ClipHistory(limit: 2, loading: try ClipStore(path: path).loadRecent(limit: 2))
        #expect(reloaded.items.map(\.title) == ["b", "c"]) // "a" evicted, "b" bumped
        #expect(reloaded.clip(id: reloaded.items[0].id)?.useCount == 2)
        #expect(reloaded.clip(id: reloaded.items[0].id)?.sourceName == "X")
    }

    @Test func asyncWritesApplyInOrder() async throws {
        let store = try ClipStore(path: nil)
        let h = ClipHistory()
        let a = try #require(h.record("a", sourceBundleID: nil, sourceName: nil))
        store.apply(a)
        store.apply(try #require(h.delete(id: a.saved!.id)))
        await withCheckedContinuation { c in store.apply(.init(), completion: { _ in c.resume() }) }
        #expect(try store.loadRecent(limit: 10).isEmpty)
    }
}

@Suite struct PasteboardFilterTests {
    @Test func skipsPasswordsAndOwnWrites() {
        #expect(PasteboardFilter.shouldRecord(types: ["public.utf8-plain-text"]))
        #expect(!PasteboardFilter.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!PasteboardFilter.shouldRecord(types: ["public.utf8-plain-text", PasteboardFilter.euclidMarker]))
    }
}
