/// Byte-level fuzzy matcher.
///
/// Ranking tiers (higher is better):
/// - contiguous substring: 1000+ (bonus at start / word boundary, shorter titles win)
/// - subsequence:          < 1000 (bonus for consecutive and word-boundary hits)
public enum FuzzyMatcher {
    public static func search(_ query: String, in items: [SearchItem], limit: Int = 50) -> [SearchItem] {
        scoredSearch(query, in: items, limit: limit).map(\.item)
    }

    /// Like `search`, but keeps scores so results from different sources can be merged.
    public static func scoredSearch(_ query: String, in items: [SearchItem], limit: Int = 50) -> [(score: Int, item: SearchItem)] {
        let q = SearchKey.make(query)
        if q.isEmpty { return items.prefix(limit).map { (0, $0) } }

        var hits: [(score: Int, index: Int)] = []
        hits.reserveCapacity(256)
        for i in items.indices {
            if let s = score(query: q, in: items[i].key) { hits.append((s, i)) }
        }
        // Stable on ties: keep original order (later: recency/frecency).
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return hits.prefix(limit).map { ($0.score, items[$0.index]) }
    }

    public static func score(query: String, in text: String) -> Int? {
        score(query: SearchKey.make(query), in: SearchKey.make(text))
    }

    static func score(query q: [UInt8], in t: [UInt8]) -> Int? {
        guard !q.isEmpty, q.count <= t.count else { return q.isEmpty ? 0 : nil }
        return q.withUnsafeBufferPointer { qb in
            t.withUnsafeBufferPointer { tb in
                substringScore(qb, tb) ?? subsequenceScore(qb, tb)
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
