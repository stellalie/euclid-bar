import Foundation

/// One clipboard history entry (text only for now; images come later).
public struct Clip: Sendable, Equatable {
    public let id: Int
    public let content: String
    public var sourceBundleID: String?
    public var sourceName: String?
    public let createdAt: Date
    public var lastUsedAt: Date
    public var useCount: Int

    public init(
        id: Int, content: String, sourceBundleID: String? = nil, sourceName: String? = nil,
        createdAt: Date, lastUsedAt: Date? = nil, useCount: Int = 1
    ) {
        self.id = id
        self.content = content
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.useCount = useCount
    }

    var searchItem: SearchItem {
        SearchItem(id: id, title: content, subtitle: sourceName ?? "", date: lastUsedAt)
    }
}
