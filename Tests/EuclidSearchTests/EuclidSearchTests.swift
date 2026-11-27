import Testing
import EuclidSearch // public API only: what an app embedding the library sees

/// A type from someone else's app, ranked without any of Euclid's own types.
private struct Command: Searchable {
    let name: String
    let searchKey: SearchKey
    init(_ name: String) { self.name = name; searchKey = SearchKey(name) }
}

@Suite struct EuclidSearchTests {
    @Test func ranksYourOwnTypes() {
        let commands = ["Activity Monitor", "Microsoft Teams", "Visual Studio Code", "Terminal"].map(Command.init)
        #expect(FuzzyMatcher.search("am", in: commands).first?.name == "Activity Monitor")
        #expect(FuzzyMatcher.search("vsc", in: commands).map(\.name) == ["Visual Studio Code"])
    }

    @Test func ranksAnyCollectionWithAKeyClosure() {
        let keyed = ["git rebase -i", "big apple sauce", "database"].map { ($0, SearchKey($0)) }
        let hits = FuzzyMatcher.scoredSearch("base", in: keyed, key: \.1)
        #expect(hits.map(\.item.0) == ["database", "git rebase -i", "big apple sauce"])
        #expect(hits.map(\.score) == hits.map(\.score).sorted(by: >))
    }

    @Test func emptyQueryKeepsOrderAndLimit() {
        let items = (0..<10).map { Command("item \($0)") }
        #expect(FuzzyMatcher.search("", in: items, limit: 3).map(\.name) == ["item 0", "item 1", "item 2"])
    }

    @Test func keysFoldCaseAndAccents() {
        #expect(SearchKey("Café") == SearchKey("cafe"))
        #expect(FuzzyMatcher.score(query: SearchKey("CAFE"), in: SearchKey("Le Café")) != nil)
    }

    @Test func keysAreCapped() {
        let long = String(repeating: "a", count: SearchKey.maxBytes * 2) + "needle"
        #expect(FuzzyMatcher.score(query: "needle", in: long) == nil)
    }

    @Test func highlightRangesPointIntoTheText() {
        let text = "Visual Studio Code"
        #expect(FuzzyMatcher.matchRanges(query: "vsc", in: text).map { String(text[$0]) } == ["V", "S", "C"])
    }
}
