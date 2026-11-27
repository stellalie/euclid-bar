import Foundation

/// Byte-level fuzzy matcher.
///
/// Ranking tiers (higher is better):
/// - contiguous substring: 1000+ (bonus at start / word boundary, shorter titles win)
/// - acronym:              ~1150, the first letter of every word ("am" → Activity Monitor), so it
///                         beats a match inside a word ("am" in Teams) but not one at a word start
/// - subsequence:          < 1000 (bonus for consecutive and word-boundary hits)
public enum FuzzyMatcher {
    /// The best `limit` items for `query`, best first. Ties keep the items' original order.
    @inlinable
    public static func search<S: Searchable>(_ query: String, in items: [S], limit: Int = 50) -> [S] {
        scoredSearch(query, in: items, limit: limit).map(\.item)
    }

    /// Like `search`, but keeps scores so results from different sources can be merged.
    @inlinable
    public static func scoredSearch<S: Searchable>(_ query: String, in items: [S], limit: Int = 50) -> [(score: Int, item: S)] {
        // A closure, not `\.searchKey`: key paths as functions aren't optimized away, ~8x slower here.
        scoredSearch(query, in: items, limit: limit) { $0.searchKey }
    }

    /// Ranks any collection: `key` returns each element's `SearchKey`. Build keys once and keep
    /// them, so a keystroke only compares bytes. An empty query returns the first `limit` items.
    @inlinable
    public static func scoredSearch<C: Collection>(_ query: String, in items: C, limit: Int = 50,
                                                   key: (C.Element) -> SearchKey) -> [(score: Int, item: C.Element)] {
        let q = SearchKey(query)
        if q.isEmpty { return items.prefix(limit).map { (0, $0) } }

        var hits: [(score: Int, order: Int, index: C.Index)] = []
        hits.reserveCapacity(256)
        var order = 0
        var i = items.startIndex
        while i != items.endIndex {
            if let s = score(query: q, in: key(items[i])) { hits.append((s, order, i)) }
            order += 1
            items.formIndex(after: &i)
        }
        // Stable on ties: keep original order.
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return hits.prefix(limit).map { ($0.score, items[$0.index]) }
    }

    /// The score of `text` for `query`, or nil when it doesn't match. Higher is better.
    public static func score(query: String, in text: String) -> Int? {
        score(query: SearchKey(query), in: SearchKey(text))
    }

    /// `score(query:in:)` on prepared keys: the fast path for ranking many items.
    public static func score(query: SearchKey, in text: SearchKey) -> Int? {
        let q = query.bytes, t = text.bytes
        guard !q.isEmpty, q.count <= t.count else { return q.isEmpty ? 0 : nil }
        return q.withUnsafeBufferPointer { qb in
            t.withUnsafeBufferPointer { tb in
                let sub = substringScore(qb, tb)
                if let acronym = acronymScore(qb, tb), acronym > sub ?? .min { return acronym }
                return sub ?? subsequenceScore(qb, tb)
            }
        }
    }

    @inline(__always)
    private static func isBoundary(_ t: UnsafeBufferPointer<UInt8>, _ i: Int) -> Bool {
        i == 0 || !isAlnum(t[i - 1])
    }

    @inline(__always)
    private static func isAlnum(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c >= 0x80
    }

    private static func substringScore(_ q: UnsafeBufferPointer<UInt8>, _ t: UnsafeBufferPointer<UInt8>) -> Int? {
        let first = q[0], n = q.count, last = t.count - n
        var best: Int?
        var i = 0
        while i <= last {
            if t[i] == first {
                var j = 1
                while j < n && t[i + j] == q[j] { j += 1 }
                if j == n {
                    var s = 1000 - min(i, 100) - min(t.count, 200) / 10
                    if isBoundary(t, i) { s += 200 }
                    if i == 0 { s += 100 }
                    if s > (best ?? .min) { best = s }
                    if i == 0 { break } // can't beat a prefix match
                }
            }
            i += 1
        }
        return best
    }

    /// The query is exactly the first letter of each word, in order: "vsc" → Visual Studio Code.
    /// Every word must take part, so long texts (clips, pages) rarely qualify by accident.
    private static func acronymScore(_ q: UnsafeBufferPointer<UInt8>, _ t: UnsafeBufferPointer<UInt8>) -> Int? {
        guard q.count >= 2 else { return nil }
        var qi = 0
        for i in 0..<t.count where isAlnum(t[i]) && isBoundary(t, i) {
            guard qi < q.count, t[i] == q[qi] else { return nil }
            qi += 1
        }
        return qi == q.count ? 1150 - min(t.count, 200) / 10 : nil
    }

    private static func subsequenceScore(_ q: UnsafeBufferPointer<UInt8>, _ t: UnsafeBufferPointer<UInt8>) -> Int? {
        var s = 0, qi = 0, prev = -2
        for ti in 0..<t.count where t[ti] == q[qi] {
            s += 10
            if ti == prev + 1 { s += 20 }
            if isBoundary(t, ti) { s += 15 }
            if prev >= 0 { s -= min(ti - prev - 1, 10) }
            prev = ti
            qi += 1
            if qi == q.count { return min(max(s, 1), 999) }
        }
        return nil
    }
}

extension FuzzyMatcher {
    /// Where `query` matches inside `text`, for highlighting. Mirrors `score`:
    /// the best contiguous substring (word start first), else the leftmost subsequence.
    /// Works on characters (case- and accent-folded one by one), so ranges are valid in `text`.
    /// Only call it for rows on screen: it's slower than `score`.
    public static func matchRanges(query: String, in text: String) -> [Range<String.Index>] {
        let q = Array(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        guard !q.isEmpty else { return [] }
        let indices = Array(text.indices.prefix(SearchKey.maxBytes))
        let t = indices.map { text[$0].description.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let qs = q.map(String.init)
        guard qs.count <= t.count else { return [] }

        func isBoundary(_ i: Int) -> Bool { i == 0 || !text[indices[i - 1]].isLetter && !text[indices[i - 1]].isNumber }
        func range(_ from: Int, _ count: Int) -> Range<String.Index> {
            indices[from]..<(from + count < indices.count ? indices[from + count] : text.endIndex)
        }

        // Contiguous: prefer a word start, else the first occurrence.
        var first: Int?
        for i in 0...(t.count - qs.count) where t[i] == qs[0] {
            guard (1..<qs.count).allSatisfy({ t[i + $0] == qs[$0] }) else { continue }
            if isBoundary(i) { return [range(i, qs.count)] }
            if first == nil { first = i }
        }
        if let first { return [range(first, qs.count)] }

        // Acronym: one letter per word, every word ("vsc" → Visual Studio Code).
        let starts = t.indices.filter { isBoundary($0) && (text[indices[$0]].isLetter || text[indices[$0]].isNumber) }
        if qs.count >= 2, starts.count == qs.count, zip(starts, qs).allSatisfy({ t[$0] == $1 }) {
            return starts.map { range($0, 1) }
        }

        // Subsequence: leftmost, merged into runs.
        var hits: [Int] = []
        var qi = 0
        for ti in t.indices where qi < qs.count && t[ti] == qs[qi] {
            hits.append(ti)
            qi += 1
        }
        guard qi == qs.count else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = hits[0], len = 1
        for h in hits.dropFirst() {
            if h == start + len { len += 1 } else { ranges.append(range(start, len)); start = h; len = 1 }
        }
        ranges.append(range(start, len))
        return ranges
    }
}

extension FuzzyMatcher {
    /// The match ranges worth drawing: a contiguous match as is; for a scattered (subsequence) match,
    /// only runs of two or more letters or runs that start a word. Lone letters mid-word
    /// ("How do I squash … c … k") are noise, so they stay plain.
    public static func displayRanges(query: String, in text: String) -> [Range<String.Index>] {
        let ranges = matchRanges(query: query, in: text)
        guard ranges.count > 1 else { return ranges }
        return ranges.filter { r in
            if text.distance(from: r.lowerBound, to: r.upperBound) >= 2 { return true }
            guard r.lowerBound > text.startIndex else { return true }
            let before = text[text.index(before: r.lowerBound)]
            return !before.isLetter && !before.isNumber
        }
    }
}
