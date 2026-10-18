import Foundation

/// In-memory clipboard history: the source of truth for search.
/// Newest (most recently copied or pasted) first. Not thread-safe: use from one thread (main).
///
/// Every mutation returns the change the persistent store must apply, so the
/// store can stay a dumb, asynchronous writer.
public final class ClipHistory {
    public struct Change: Equatable, Sendable {
        public var saved: Clip?
        public var deletedIDs: [Int] = []
    }

    public let limit: Int
    /// Entries larger than this are ignored rather than stored.
    public static let maxContentBytes = 2_000_000

    public private(set) var items: [SearchItem] = []
    private var clips: [Int: Clip] = [:]
    private var idByContent: [String: Int] = [:]
    private var nextID = 1

    public init(limit: Int = 5_000, loading existing: [Clip] = []) {
        self.limit = limit
        let sorted = existing.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit)
        for clip in sorted {
            clips[clip.id] = clip
            idByContent[Self.key(clip.content, clip.kind)] = clip.id
            items.append(clip.searchItem)
            nextID = max(nextID, clip.id + 1)
        }
    }

    public var count: Int { items.count }
    public func clip(id: Int) -> Clip? { clips[id] }

    /// A new copy event. Re-copying existing content moves it to the top.
    @discardableResult
    public func record(_ content: String, kind: Clip.Kind = .text, meta: String? = nil,
                       sourceBundleID: String?, sourceName: String?, at now: Date = Date()) -> Change? {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.utf8.count <= Self.maxContentBytes else { return nil }

        if let id = idByContent[Self.key(content, kind)], var clip = clips[id] {
            clip.lastUsedAt = now
            clip.useCount += 1
            clip.sourceBundleID = sourceBundleID ?? clip.sourceBundleID
            clip.sourceName = sourceName ?? clip.sourceName
            moveToFront(clip)
            return Change(saved: clip)
        }

        let clip = Clip(id: nextID, content: content, kind: kind, meta: meta, sourceBundleID: sourceBundleID,
                        sourceName: sourceName, createdAt: now)
        nextID += 1
        clips[clip.id] = clip
        idByContent[Self.key(content, kind)] = clip.id
        items.insert(clip.searchItem, at: 0)

        var change = Change(saved: clip)
        while items.count > limit, let oldest = items.last {
            removeFromMemory(id: oldest.id)
            change.deletedIDs.append(oldest.id)
        }
        return change
    }

    /// The user pasted/copied an entry from Euclid: bump it to the top.
    @discardableResult
    public func markUsed(id: Int, at now: Date = Date()) -> Change? {
        guard var clip = clips[id] else { return nil }
        clip.lastUsedAt = now
        clip.useCount += 1
        moveToFront(clip)
        return Change(saved: clip)
    }

    @discardableResult
    public func delete(id: Int) -> Change? {
        guard clips[id] != nil else { return nil }
        removeFromMemory(id: id)
        return Change(deletedIDs: [id])
    }

    public func removeAll() -> Change {
        let ids = items.map(\.id)
        items.removeAll()
        clips.removeAll()
        idByContent.removeAll()
        return Change(deletedIDs: ids)
    }

    /// Dedupe key: the same text and the same file copied as a file are different clips.
    private static func key(_ content: String, _ kind: Clip.Kind) -> String {
        kind == .text ? content : "\(kind.rawValue)\u{0}\(content)"
    }

    private func moveToFront(_ clip: Clip) {
        clips[clip.id] = clip
        if let i = items.firstIndex(where: { $0.id == clip.id }) { items.remove(at: i) }
        items.insert(clip.searchItem, at: 0)
    }

    private func removeFromMemory(id: Int) {
        guard let clip = clips.removeValue(forKey: id) else { return }
        idByContent.removeValue(forKey: Self.key(clip.content, clip.kind))
        if let i = items.firstIndex(where: { $0.id == id }) { items.remove(at: i) }
    }
}
