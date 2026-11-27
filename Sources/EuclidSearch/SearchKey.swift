import Foundation

/// Text prepared for matching: case- and accent-folded UTF-8, capped at `maxBytes`.
/// Make it once per item (not per keystroke), so typing only compares bytes.
public struct SearchKey: Sendable, Hashable {
    /// Only the first N bytes are searchable, so a 5 MB paste can't slow typing.
    public static let maxBytes = 2048

    @usableFromInline let bytes: [UInt8]

    public init(_ text: String) {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        bytes = Array(folded.utf8.prefix(Self.maxBytes))
    }

    @inlinable public var isEmpty: Bool { bytes.isEmpty }
}

/// Anything with a prepared key can be ranked by `FuzzyMatcher.search`.
public protocol Searchable {
    var searchKey: SearchKey { get }
}
