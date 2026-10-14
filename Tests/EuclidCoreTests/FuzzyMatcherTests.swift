import Foundation
import Testing
@testable import EuclidCore

#if DEBUG
let isDebugBuild = true
#else
let isDebugBuild = false
#endif

@Suite struct FuzzyMatcherTests {
    @Test func noMatchReturnsNil() {
        #expect(FuzzyMatcher.score(query: "xyz", in: "git rebase") == nil)
    }

    @Test func substringBeatsSubsequence() throws {
        let sub = try #require(FuzzyMatcher.score(query: "base", in: "git rebase -i"))
        let seq = try #require(FuzzyMatcher.score(query: "base", in: "big apple sauce"))
        #expect(sub > seq)
    }

    @Test func prefixBeatsWordBoundaryBeatsMiddle() throws {
        let prefix = try #require(FuzzyMatcher.score(query: "git", in: "git status"))
        let word = try #require(FuzzyMatcher.score(query: "git", in: "run git status"))
        let middle = try #require(FuzzyMatcher.score(query: "git", in: "digital status"))
        #expect(prefix > word)
        #expect(word > middle)
    }

    @Test func caseAndDiacriticInsensitive() {
        #expect(FuzzyMatcher.score(query: "CAFE", in: "Café au lait") != nil)
        #expect(FuzzyMatcher.score(query: "café", in: "CAFE") != nil)
    }

    @Test func searchRanksAndLimits() {
        let items = ["digital", "git status", "run git push", "nothing"].enumerated().map {
            SearchItem(id: $0.offset, title: $0.element)
        }
        let r = FuzzyMatcher.search("git", in: items, limit: 2)
        #expect(r.map(\.title) == ["git status", "run git push"])
    }

    @Test func emptyQueryReturnsFirstItems() {
        let items = (0..<10).map { SearchItem(id: $0, title: "item \($0)") }
        #expect(FuzzyMatcher.search("", in: items, limit: 3).map(\.id) == [0, 1, 2])
    }

    @Test func hugeEntryIsTruncatedForSearch() {
        let huge = String(repeating: "a", count: 1_000_000) + "needle"
        #expect(FuzzyMatcher.score(query: "needle", in: huge) == nil)
    }

    /// Budget: keystroke -> results < 8 ms. Search must take a small slice of that.
    /// Run with `swift test -c release` for meaningful numbers.
    @Test(.disabled(if: isDebugBuild, "debug builds are ~100x slower; run `make perf`"))
    func performance5kItems() {
        let words = ["git", "rebase", "https://staging.example.com", "docker", "kubectl", "SELECT", "error", "token", "café"]
        let items = (0..<5_000).map { i in
            SearchItem(id: i, title: (0..<30).map { words[($0 * 7 + i) % words.count] }.joined(separator: " "))
        }
        let clock = ContinuousClock()
        var worst = Duration.zero
        for q in ["g", "gi", "git", "reb", "stag", "zzz", "kctl"] {
            let d = clock.measure { _ = FuzzyMatcher.search(q, in: items) }
            worst = max(worst, d)
        }
        print("worst search over 5k items: \(worst)")
        #expect(worst < .milliseconds(8))
    }

    /// The real typing path: 5k clips + 5k history pages (title + URL), searched separately and merged.
    @Test(.disabled(if: isDebugBuild, "debug builds are ~100x slower; run `make perf`"))
    func performance5kClipsPlus5kHistory() {
        let words = ["git", "rebase", "docker", "kubectl", "SELECT", "error", "token", "swift", "actor", "pull"]
        let clips = (0..<5_000).map { i in
            SearchItem(id: i, title: (0..<30).map { words[($0 * 7 + i) % words.count] }.joined(separator: " "))
        }
        let pages = (0..<5_000).map { i in
            let title = (0..<8).map { words[($0 * 3 + i) % words.count] }.joined(separator: " ")
            return HistoryEntry(url: "https://example\(i % 50).com/\(words[i % words.count])/\(i)?q=\(title.prefix(20))",
                                title: title, browser: "Dia", lastVisit: Date(), visitCount: 1).searchItem(id: i)
        }
        let clock = ContinuousClock()
        var worst = Duration.zero
        for q in ["g", "gi", "git", "reb", "pull req", "zzz", "kctl", "example7"] {
            let d = clock.measure {
                let a = FuzzyMatcher.scoredSearch(q, in: clips, limit: 50)
                let b = FuzzyMatcher.scoredSearch(q, in: pages, limit: 30)
                _ = (a + b).sorted { $0.score > $1.score }.prefix(50)
            }
            worst = max(worst, d)
        }
        print("worst search over 5k clips + 5k pages: \(worst)")
        #expect(worst < .milliseconds(8))
    }
}
