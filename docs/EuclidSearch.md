# EuclidSearch

The fuzzy matcher behind Euclid's bar, as its own Swift library. It has no dependencies but
Foundation and no AppKit, and it builds on macOS and Linux. Euclid itself uses it through
`EuclidCore`, which re-exports it, so the app and any other user run the same code.

> **License:** the library is covered by the repository's license (proprietary, see
> [LICENSE](../LICENSE)). Publishing it for others to embed needs a license decision first.

## Use it

```swift
// Package.swift
.product(name: "EuclidSearch", package: "euclid-bar")
```

```swift
import EuclidSearch

struct Command: Searchable {
    let name: String
    let searchKey: SearchKey          // build once per item, not per keystroke
    init(_ name: String) { self.name = name; searchKey = SearchKey(name) }
}

let commands = ["Activity Monitor", "Microsoft Teams", "Visual Studio Code"].map(Command.init)
FuzzyMatcher.search("vsc", in: commands)            // [Visual Studio Code]
FuzzyMatcher.scoredSearch("am", in: commands)       // [(score, item)], best first, for merging sources

// Any collection, without conforming: say where the key is.
FuzzyMatcher.scoredSearch("base", in: rows) { $0.key }

// Highlighting, for the rows on screen only.
FuzzyMatcher.displayRanges(query: "vsc", in: "Visual Studio Code")
```

## What it does

- **Three tiers, one score.** A contiguous match scores 1000+, with bonuses at a word start and for
  shorter text. An acronym (`am` → Activity Monitor) scores ~1150. A scattered subsequence scores
  under 1000. Scores from different lists can be compared, so results from several sources merge
  into one ranking.
- **Stable.** Ties keep your order, so the list doesn't reshuffle under the cursor.
- **Bytes on the hot path.** `SearchKey` folds case and accents once and caps the text at 2048 bytes,
  so a 5 MB paste can't slow typing. Each keystroke only compares bytes.
- **Fast.** Over 10,000 items, every keystroke stays under Euclid's 8 ms budget
  (`swift test -c release --filter performance`).

## Performance note for callers

Pass a closure (`{ $0.key }`), not a key path (`\.key`), to `scoredSearch(_:in:limit:key:)`. A key
path used as a function isn't optimized across modules, and that made ranking ~8x slower in
benchmarks.
