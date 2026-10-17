import Foundation
import Testing
@testable import EuclidCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeApp(_ dir: URL, _ name: String, id: String?, backgroundOnly: Bool = false) throws {
    let contents = dir.appendingPathComponent("\(name).app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = [:]
    if let id { info["CFBundleIdentifier"] = id }
    if backgroundOnly { info["LSBackgroundOnly"] = true }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
}

@Suite struct AppIndexTests {
    @Test func findsAppsOneLevelDownSkipsHelpersAndDuplicates() throws {
        let root = try tempDir(), other = try tempDir()
        try makeApp(root, "Ghostty", id: "com.mitchellh.ghostty")
        try makeApp(root.appendingPathComponent("Utilities"), "Terminal", id: "com.apple.Terminal")
        try makeApp(root, "Helper", id: "x.helper", backgroundOnly: true)
        try makeApp(other, "Ghostty copy", id: "com.mitchellh.ghostty") // same bundle ID: first wins
        // Nested inside a bundle: never an app of its own.
        try makeApp(root.appendingPathComponent("Ghostty.app/Contents/Library"), "Inner", id: "x.inner")

        let apps = AppIndex.scan(folders: [root.path, other.path, "/nope"])
        #expect(apps.map(\.name) == ["Ghostty", "Terminal"])
        #expect(apps[0].bundleID == "com.mitchellh.ghostty")
        #expect(apps[0].searchItem(id: 0).subtitle == root.appendingPathComponent("Ghostty.app").path)
    }

    @Test func acceptsASingleBundlePath() throws {
        let root = try tempDir()
        try makeApp(root, "Finder", id: "com.apple.finder")
        let apps = AppIndex.scan(folders: [root.appendingPathComponent("Finder.app").path])
        #expect(apps.map(\.name) == ["Finder"])
    }

    @Test func fuzzyFindsAppsByInitials() {
        let items = ["Visual Studio Code", "Safari", "System Settings"].enumerated()
            .map { SearchItem(id: $0.offset, title: $0.element) }
        #expect(FuzzyMatcher.search("vsc", in: items).first?.title == "Visual Studio Code")
        #expect(FuzzyMatcher.search("saf", in: items).first?.title == "Safari")
    }
}

@Suite struct ProjectScannerTests {
    @Test func findsReposStopsAtRepoAndSkipsNoise() throws {
        let root = try tempDir()
        let fm = FileManager.default
        for repo in ["euclid-bar", "work/api", "work/web", "deep/a/b/c/too-deep"] {
            try fm.createDirectory(at: root.appendingPathComponent("\(repo)/.git"), withIntermediateDirectories: true)
        }
        // A nested repo inside a repo, and one inside node_modules: both skipped.
        try fm.createDirectory(at: root.appendingPathComponent("euclid-bar/vendor/x/.git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("web/node_modules/pkg/.git"), withIntermediateDirectories: true)
        // A worktree: `.git` is a file.
        try fm.createDirectory(at: root.appendingPathComponent("wt"), withIntermediateDirectories: true)
        try "gitdir: ../euclid-bar/.git/worktrees/wt".write(to: root.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)

        let found = ProjectScanner.scan(roots: [root.path, root.path, "/nope"], maxDepth: 3)
        #expect(found.map(\.name) == ["euclid-bar", "api", "web", "wt"])
        #expect(found[1].path == root.appendingPathComponent("work/api").path)
    }

    @Test func abbreviatesHome() {
        #expect(ProjectScanner.abbreviate("/Users/me/code/x", home: "/Users/me") == "~/code/x")
        #expect(ProjectScanner.abbreviate("/Users/meow/x", home: "/Users/me") == "/Users/meow/x")
        #expect(ProjectScanner.abbreviate("/Users/me", home: "/Users/me") == "~")
    }
}

@Suite struct FrecencyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func pickedResultEarnsBonusForSameAndRelatedQueries() {
        var f = Frecency()
        f.record(query: "Saf", key: "app:/Applications/Safari.app", at: now)
        let same = f.bonuses(for: "saf", now: now)["app:/Applications/Safari.app"] ?? 0
        let shorter = f.bonuses(for: "sa", now: now)["app:/Applications/Safari.app"] ?? 0
        let longer = f.bonuses(for: "safari", now: now)["app:/Applications/Safari.app"] ?? 0
        let unrelated = f.bonuses(for: "xcode", now: now)["app:/Applications/Safari.app"] ?? 0
        #expect(same == 250)
        #expect(shorter > unrelated && longer > unrelated && shorter < same)
        #expect(unrelated > 0) // frequently used things get a small nudge everywhere
    }

    @Test func moreAndRecentPicksWinAndBonusIsCapped() {
        var f = Frecency()
        for _ in 0..<3 { f.record(query: "s", key: "a", at: now) }
        f.record(query: "s", key: "b", at: now)
        f.record(query: "s", key: "c", at: now.addingTimeInterval(-60 * 86_400)) // 60 days ago
        let b = f.bonuses(for: "s", now: now)
        #expect(b["a"]! > b["b"]! && b["b"]! > b["c"]!)
        for _ in 0..<1000 { f.record(query: "s", key: "a", at: now) }
        #expect(f.bonuses(for: "s", now: now)["a"] == Frecency.maxBonus)
        #expect(f.top(2, now: now) == ["a", "b"])
    }

    @Test func forgetsOldestPastLimitAndForgetKey() {
        var f = Frecency()
        for i in 0..<(Frecency.limit + 5) {
            f.record(query: "q\(i)", key: "k\(i)", at: now.addingTimeInterval(Double(i)))
        }
        #expect(f.picks.count == Frecency.limit)
        #expect(!f.picks.contains { $0.key == "k0" })
        f.forget(key: "k10")
        #expect(!f.picks.contains { $0.key == "k10" })
    }

    @Test func storeRoundTrips() throws {
        let path = try tempDir().appendingPathComponent("ranking.sqlite").path
        let store = try FrecencyStore(path: path)
        var f = Frecency()
        try store.save(f.record(query: "gh", key: "action:Search GitHub", at: now))
        try store.save(f.record(query: "gh", key: "action:Search GitHub", at: now))
        try store.save(f.record(query: "x", key: "app:/X.app", at: now))
        try store.forget(key: "app:/X.app")
        let loaded = try FrecencyStore(path: path).load()
        #expect(loaded.picks == [Frecency.Pick(query: "gh", key: "action:Search GitHub", count: 2, last: now)])
    }
}

@Suite struct CalculatorTests {
    func value(_ s: String) -> Double? { Calculator.evaluate(s)?.value }

    @Test func arithmetic() {
        #expect(value("12 * (3 + 4)") == 84)
        #expect(value("2^10") == 1024)
        #expect(value("2**3**2") == 512) // right-associative
        #expect(value("-3 + 5") == 2)
        #expect(value("10 / 4") == 2.5)
        #expect(value("20% of 80") == 16)
        #expect(value("50%") == 0.5)
        #expect(value("sqrt(2) * sqrt(2)").map { abs($0 - 2) < 1e-9 } == true)
        #expect(value("1,000 * 3") == 3000)
        #expect(value("0xff + 1") == 256)
        #expect(value("1e3 + 1") == 1001)
        #expect(value("10k / 4") == 2500)
        #expect(value("6 × 7") == 42)
        #expect(value("2 * pi").map { abs($0 - 6.283185307) < 1e-6 } == true)
    }

    @Test func unitConversions() {
        #expect(value("1.5 gb in mb") == 1500)
        #expect(value("1gib to mib") == 1024)
        #expect(value("10 km in mi").map { abs($0 - 6.2137119) < 1e-6 } == true)
        #expect(value("212 f in c").map { abs($0 - 100) < 1e-9 } == true)
        #expect(value("0 c to k").map { abs($0 - 273.15) < 1e-9 } == true)
        #expect(value("90 min in h") == 1.5)
        #expect(value("2 * 3 kg in g") == 6000)
        #expect(Calculator.evaluate("1 kg in m") == nil) // different dimensions
        #expect(Calculator.evaluate("1.5 gb in mb")?.text == "1500 mb")
    }

    @Test func staysQuietForThingsThatArentMath() {
        for s in ["", "safari", "42", "-5", "pi", "2026-10-16", "euclid-bar", "git rebase -i", "1/0", "sqrt(-1)",
                  "euclid-bar 2", "v1.2.3", "how to in swift"] {
            #expect(Calculator.evaluate(s) == nil, "\(s)")
        }
    }

    @Test func formatting() {
        #expect(Calculator.evaluate("1000 * 1000")?.display == "1,000,000")
        #expect(Calculator.evaluate("1000 * 1000")?.text == "1000000")
        #expect(Calculator.evaluate("1 / 3")?.text == "0.3333333333")
        #expect(Calculator.evaluate("-1234.5 * 1")?.display == "-1,234.5")
        #expect(Calculator.evaluate("0.1 + 0.2")?.text == "0.3")
    }
}

@Suite struct AliasTests {
    @Test func exactAliasAndArgument() {
        let a = Aliases(["gh": "Search GitHub", "Code": "Visual Studio Code"])
        #expect(a.match("gh") == .init(target: "Search GitHub", argument: nil))
        #expect(a.match(" GH  swift testing ") == .init(target: "Search GitHub", argument: "swift testing"))
        #expect(a.match("code") == .init(target: "Visual Studio Code", argument: nil))
        #expect(a.match("ghost") == nil)
        #expect(a.match("gh ") == .init(target: "Search GitHub", argument: nil))
        #expect(a.alias(for: "Search GitHub") == "gh")
    }
}

@Suite struct LauncherConfigTests {
    @Test func defaultsCoverNewSections() throws {
        let c = try ConfigLoader.parse(DefaultConfig.text).config
        #expect(c.appsEnabled && c.filesEnabled)
        #expect(c.projectRoots.contains("~/code"))
        #expect(c.projectOpen == #"open "$1""#)
        #expect(c.aliases.match("gh x") == .init(target: "Search GitHub", argument: "x"))
        #expect(c.aliases.match("g") == .init(target: "Search web", argument: nil))
    }

    @Test func parsesAppsProjectsFilesSearchAliases() throws {
        let toml = """
        [apps]
        enabled = false
        folders = ["~/Tools"]

        [projects]
        roots = ["~/work"]
        depth = 2
        open  = 'zed "$1"'

        [files]
        enabled = false
        limit   = 3

        [search]
        favorites = ["Ghostty", "euclid-bar"]

        [aliases]
        code = "Visual Studio Code"

        [[action]]
        name  = "npm"
        alias = "npm"
        run   = 'open "https://www.npmjs.com/package/$1"'
        """
        let loaded = try ConfigLoader.parse(toml)
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        let c = loaded.config
        #expect(!c.appsEnabled)
        #expect(c.appFolders == AppIndex.defaultFolders + ["~/Tools"])
        #expect(c.projectRoots == ["~/work"] && c.projectDepth == 2 && c.projectOpen == #"zed "$1""#)
        #expect(!c.filesEnabled && c.filesLimit == 3)
        #expect(c.favorites == ["Ghostty", "euclid-bar"])
        #expect(c.aliases.targets == ["code": "Visual Studio Code", "npm": "npm"])
    }

    @Test func badValuesBecomeWarnings() throws {
        let toml = """
        apps = 1
        [projects]
        depth = 99
        roots = "~/code"
        [files]
        limit = 0
        nope = 1
        [aliases]
        "a b" = "X"
        x = 3
        [[action]]
        name = "A"
        run = "true"
        alias = "has space"
        """
        let loaded = try ConfigLoader.parse(toml)
        let messages = loaded.issues.map(\.message)
        #expect(messages.contains("apps must be a table: [apps]"))
        #expect(messages.contains("projects.depth must be a number from 1 to 6"))
        #expect(messages.contains("projects.roots must be a list of strings"))
        #expect(messages.contains("files.limit must be a number from 1 to 30"))
        #expect(messages.contains("[files]: unknown key 'nope'"))
        #expect(messages.contains("aliases: 'a b' can't contain spaces"))
        #expect(messages.contains { $0.hasPrefix("aliases.x") })
        #expect(messages.contains { $0.contains("alias can't be empty or contain spaces") })
        #expect(loaded.config.aliases.targets.isEmpty)
    }
}

@Suite struct LauncherPerformanceTests {
    /// The extra per-keystroke work this adds: learned bonuses over a full pick table,
    /// the calculator check, and matching 300 apps + 300 projects.
    @Test(.disabled(if: isDebugBuild, "debug builds are ~100x slower; run `make perf`"))
    func performanceKeystrokeExtras() {
        var f = Frecency()
        let now = Date()
        for i in 0..<Frecency.limit { f.record(query: "q\(i % 400)", key: "app:/Applications/App\(i % 300).app", at: now) }
        let apps = (0..<300).map { SearchItem(id: $0, title: "Application Number \($0)", subtitle: "/Applications/App\($0).app") }
        let projects = (0..<300).map { ProjectEntry(name: "project-\($0)", path: "/Users/me/code/project-\($0)").searchItem(id: $0) }
        _ = Calculator.evaluate("1 + 1") // first call pays one-time regex setup, like the app at launch
        let clock = ContinuousClock()
        var worst = Duration.zero
        for q in ["a", "ap", "app", "proj", "q12", "12 * 3", "1.5 gb in mb", "zzz"] {
            let d = clock.measure {
                _ = f.bonuses(for: q, now: now)
                _ = Calculator.evaluate(q)
                _ = FuzzyMatcher.scoredSearch(q, in: apps, limit: 20)
                _ = FuzzyMatcher.scoredSearch(q, in: projects, limit: 20)
            }
            worst = max(worst, d)
        }
        print("worst keystroke extras: \(worst)")
        #expect(worst < .milliseconds(1))
    }
}
