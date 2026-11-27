import Foundation
@_exported import EuclidSearch

/// One searchable row. The search key is computed once at creation so the
/// per-keystroke path only compares bytes.
public struct SearchItem: Sendable, Identifiable, Searchable {
    public let id: Int
    public let title: String
    public let subtitle: String
    public let date: Date?
    public let searchKey: SearchKey

    /// `searchText` is what matching runs against (defaults to the title).
    public init(id: Int, title: String, subtitle: String = "", date: Date? = nil, searchText: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.date = date
        self.searchKey = SearchKey(searchText ?? title)
    }
}
