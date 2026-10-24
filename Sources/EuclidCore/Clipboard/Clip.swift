import Foundation

/// One clipboard history entry: text, an image, or copied files.
public struct Clip: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// `content` is the text.
        case text
        /// `content` is the stored PNG's file name (its SHA-256, so equal images dedupe);
        /// `meta` is its size, e.g. "1280×720".
        case image
        /// `content` is the file paths, one per line.
        case files
    }

    public let id: Int
    public let content: String
    public var kind: Kind
    public var meta: String?
    public var sourceBundleID: String?
    public var sourceName: String?
    public let createdAt: Date
    public var lastUsedAt: Date
    public var useCount: Int

    public init(
        id: Int, content: String, kind: Kind = .text, meta: String? = nil, sourceBundleID: String? = nil, sourceName: String? = nil,
        createdAt: Date, lastUsedAt: Date? = nil, useCount: Int = 1
    ) {
        self.id = id
        self.content = content
        self.kind = kind
        self.meta = meta
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.useCount = useCount
    }

    public var paths: [String] { kind == .files ? content.split(separator: "\n").map(String.init) : [] }

    var searchItem: SearchItem {
        switch kind {
        case .text:
            return SearchItem(id: id, title: content, subtitle: sourceName ?? "", date: lastUsedAt)
        case .image:
            let title = "Image" + (meta.map { " · \($0)" } ?? "")
            return SearchItem(id: id, title: title, subtitle: sourceName ?? "", date: lastUsedAt,
                              searchText: "\(title) image picture screenshot \(sourceName ?? "")")
        case .files:
            let names = paths.map { ($0 as NSString).lastPathComponent }
            let title = names.count == 1 ? names[0] : "\(names.count) files: \(names.joined(separator: ", "))"
            return SearchItem(id: id, title: title, subtitle: sourceName ?? "", date: lastUsedAt,
                              searchText: "\(title) \(content)")
        }
    }
}
