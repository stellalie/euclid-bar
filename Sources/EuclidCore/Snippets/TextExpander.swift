import Foundation

/// Spots a snippet keyword in what's being typed in any app (`[expansion] enabled`).
/// Fed one keystroke at a time; says what to delete and what to put in its place.
///
/// - A keyword that starts with a symbol (`;sig`, `:date`, `!!email`) expands as soon as
///   it's typed, wherever it is.
/// - A plain word (`standup`) expands only as a whole word, once you type a space or
///   punctuation after it, so "standups" or "mystandup" never fire.
public struct TextExpander: Sendable {
    public struct Match: Equatable, Sendable {
        public let snippet: Snippet
        /// Characters to delete before the cursor: the keyword, plus the delimiter after a word.
        public let deleteCount: Int
        /// Typed back after the expansion: the delimiter that ended a word keyword, else "".
        public let suffix: String
    }

    /// Characters that end a word keyword. Return and tab are left alone: they submit or move focus.
    static let delimiters: Set<Character> = [" ", ".", ",", ";", ":", "!", "?", ")"]

    private let triggers: [(keyword: String, snippet: Snippet)]
    private let longest: Int
    /// The last few characters typed in the current text field, oldest first.
    private var buffer = ""

    public init(snippets: [Snippet]) {
        var seen = Set<String>()
        triggers = snippets.compactMap { s in
            guard let k = s.keyword, !k.isEmpty, seen.insert(k).inserted else { return nil }
            return (k, s)
        }
        longest = triggers.map(\.keyword.count).max() ?? 0
    }

    public var isEmpty: Bool { triggers.isEmpty }

    /// Whether the keyword expands the moment it's typed (it starts with a symbol).
    public static func isImmediate(_ keyword: String) -> Bool {
        guard let first = keyword.first else { return false }
        return !(first.isLetter || first.isNumber)
    }

    /// Text was typed (usually one character). Returns the expansion it completes, if any.
    public mutating func typed(_ text: String) -> Match? {
        guard !triggers.isEmpty else { return nil }
        for ch in text {
            buffer.append(ch)
            if let match = check(after: ch) {
                buffer = ""
                return match
            }
        }
        if buffer.count > longest + 1 { buffer = String(buffer.suffix(longest + 1)) }
        return nil
    }

    public mutating func deleteBackward() {
        if !buffer.isEmpty { buffer.removeLast() }
    }

    /// The cursor moved somewhere we can't follow (a click, an arrow key, another app).
    public mutating func reset() { buffer = "" }

    private func check(after ch: Character) -> Match? {
        for t in triggers where Self.isImmediate(t.keyword) && buffer.hasSuffix(t.keyword) {
            return Match(snippet: t.snippet, deleteCount: t.keyword.count, suffix: "")
        }
        guard Self.delimiters.contains(ch) else { return nil }
        let word = buffer.dropLast()
        for t in triggers where !Self.isImmediate(t.keyword) && word.hasSuffix(t.keyword) {
            let before = word.dropLast(t.keyword.count).last
            guard before.map({ !($0.isLetter || $0.isNumber) }) ?? true else { continue }
            return Match(snippet: t.snippet, deleteCount: t.keyword.count + 1, suffix: String(ch))
        }
        return nil
    }

    /// Keywords that can never be typed out because a symbol keyword inside them fires on the way:
    /// `;s` and `;sig` → `;sig` is shadowed by `;s`.
    public static func shadowedKeywords(in snippets: [Snippet]) -> [(short: String, long: String)] {
        let keywords = snippets.compactMap(\.keyword).filter { !$0.isEmpty }
        var out: [(short: String, long: String)] = []
        for long in keywords {
            // A word keyword waits for its delimiter, so a symbol keyword anywhere in it fires first.
            let typedFirst = isImmediate(long) ? String(long.dropLast()) : long
            if let short = keywords.first(where: { $0 != long && isImmediate($0) && typedFirst.contains($0) }) {
                out.append((short, long))
            }
        }
        return out
    }
}
