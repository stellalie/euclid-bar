import Foundation

/// The speed promise, checked in CI (`euclid-bar --speed-budget`, release build, in the render job):
/// every keystroke searches 10k+ items (5k clips, 5k history pages, apps, projects, plugin rows)
/// the way the panel does, and the slowest keystroke must stay under `limit`.
public enum SearchBudget {
    public static let limit = Duration.milliseconds(8)

    public struct Report: Sendable {
        public let items: Int
        /// Per typed prefix, the median of a few runs (one slow scheduler tick isn't a regression).
        public let timings: [(query: String, time: Duration)]
        public var worst: (query: String, time: Duration) { timings.max { $0.time < $1.time } ?? ("", .zero) }
        public var passed: Bool { worst.time < SearchBudget.limit }
    }

    /// What someone types, one keystroke at a time.
    static let typed = ["git rebase", "kctl", "pull req", "1.5 gb in mb", "zzz", "example7"]

    public static func run(runs: Int = 5) -> Report {
        let f = fixture()
        let clock = ContinuousClock()
        var timings: [(String, Duration)] = []
        for phrase in typed {
            for end in phrase.indices.dropFirst().map({ $0 }) + [phrase.endIndex] {
                let q = String(phrase[..<end])
                var samples: [Duration] = []
                for _ in 0..<runs { samples.append(clock.measure { keystroke(q, f) }) }
                timings.append((q, samples.sorted()[runs / 2]))
            }
        }
        return Report(items: f.all.reduce(0) { $0 + $1.items.count }, timings: timings)
    }

    struct Fixture { let all: [(items: [SearchItem], limit: Int)] }

    /// The panel's per-keystroke work: each source searched with its row limit, merged, plus the answers.
    static func keystroke(_ q: String, _ f: Fixture) {
        var scored: [Int] = []
        for source in f.all { scored += FuzzyMatcher.scoredSearch(q, in: source.items, limit: source.limit).map(\.score) }
        scored.sort(by: >)
        _ = Calculator.evaluate(q)
        _ = DevTransforms.evaluate(q)
    }

    static func fixture() -> Fixture {
        let words = ["git", "rebase", "docker", "kubectl", "SELECT", "error", "token", "swift", "actor", "pull",
                     "request", "café", "staging", "deploy", "README"]
        func phrase(_ n: Int, _ seed: Int, _ step: Int) -> String {
            (0..<n).map { words[($0 * step + seed) % words.count] }.joined(separator: " ")
        }
        let clips = (0..<5_000).map { SearchItem(id: $0, title: phrase(30, $0, 7)) }
        let pages = (0..<5_000).map { i in
            let title = phrase(8, i, 3)
            return HistoryEntry(url: "https://example\(i % 50).com/\(words[i % words.count])/\(i)?q=\(title.prefix(20))",
                                title: title, browser: "Dia", lastVisit: Date(), visitCount: 1).searchItem(id: i)
        }
        let apps = (0..<400).map { SearchItem(id: $0, title: "\(words[$0 % words.count].capitalized) App \($0)") }
        let projects = (0..<200).map { SearchItem(id: $0, title: "\(words[$0 % words.count])-service-\($0)") }
        let plugin = (0..<300).map { SearchItem(id: $0, title: "PR #\($0): \(phrase(6, $0, 5))") }
        return Fixture(all: [(apps, 20), (projects, 20), (plugin, 15), (clips, 50), (pages, 30)])
    }
}
