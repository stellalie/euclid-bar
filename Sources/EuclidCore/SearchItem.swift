import Foundation

/// One searchable row. The search key is computed once at creation so the
/// per-keystroke path only compares bytes.
public struct SearchItem: Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let subtitle: String
    let key: [UInt8]

    public init(id: Int, title: String, subtitle: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.key = SearchKey.make(title)
    }
}

enum SearchKey {
    /// Only the first N bytes are searchable, so a 5 MB paste can't slow typing.
    static let maxBytes = 2048

    static func make(_ s: String) -> [UInt8] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Array(folded.utf8.prefix(maxBytes))
    }
}
