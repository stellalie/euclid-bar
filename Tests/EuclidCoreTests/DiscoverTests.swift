import Foundation
import Testing
@testable import EuclidCore

@Suite struct ThemeColorsTests {
    @Test func oklabRoundTrips() {
        for hex in ["#000000", "#ffffff", "#7c5cff", "#1a1b26", "#fdf6e3", "#ff8a3d"] {
            #expect(OKLab(hex: hex).hex == hex, "\(hex)")
        }
    }

    @Test func mixingIsEvenInLightness() {
        let mid = OKLab(hex: "#000000").mixed(with: OKLab(hex: "#ffffff"), 0.5)
        #expect(abs(mid.L - 0.5) < 0.001)
    }

    @Test func threeInputsMakeAWholeTheme() {
        let p = ThemePalette(background: "#1a1b26", text: "#c0caf5", accent: "#7aa2f7")
        let c = ThemeColors.derive(p)
        let bg = OKLab(hex: c.background).L, text = OKLab(hex: c.text).L
        // Each level sits between the background and the text, in order.
        let levels = [c.border, c.muted, c.subtext].map { OKLab(hex: $0).L }
        #expect(levels.allSatisfy { $0 > bg && $0 < text })
        #expect(levels == levels.sorted())
        // Footer and card step below the background; the selection leans to the accent.
        #expect(OKLab(hex: c.footer).L < bg)
        #expect(OKLab(hex: c.card).L < OKLab(hex: c.footer).L)
        #expect(OKLab(hex: c.selection).b < OKLab(hex: c.background).b) // toward blue
    }

    @Test func contrastSpreadsLevelsAndOverridesHandPickedOnes() {
        let nord = Themes.builtIn["nord"]!
        #expect(ThemeColors.derive(nord).muted == nord.muted) // as designed
        let low = ThemeColors.derive(nord, contrast: 0), high = ThemeColors.derive(nord, contrast: 100)
        #expect(OKLab(hex: high.muted).L > OKLab(hex: low.muted).L)
        #expect(OKLab(hex: high.subtext).L > OKLab(hex: low.subtext).L)
    }

    @Test func lightThemesStepDownToo() {
        let c = ThemeColors.derive(Themes.builtIn["catppuccin-latte"]!)
        #expect(OKLab(hex: c.footer).L < OKLab(hex: c.background).L)
    }

    @Test func lightThemesFirmUpPaleLevels() {
        let latte = Themes.builtIn["catppuccin-latte"]!
        let c = ThemeColors.derive(latte)
        // Dim text moves toward the (dark) text colour; the selection leans toward the accent.
        #expect(OKLab(hex: c.muted).L < OKLab(hex: latte.muted!).L)
        #expect(OKLab(hex: c.subtext).L < OKLab(hex: latte.subtext!).L)
        #expect(c.selection != latte.selection!)
    }

    @Test func contrastConfig() throws {
        let dir = URL(fileURLWithPath: "/home/me/.config/euclid")
        func parse(_ s: String) throws -> LoadedConfig { try ConfigLoader.parse(s, directory: dir, fileExists: { _ in true }, readFile: { _ in nil }) }
        #expect(try parse("").config.appearance.contrast == 50)
        let c = try parse("[appearance]\ncontrast = 80")
        #expect(c.config.appearance.contrast == 80)
        #expect(c.issues.isEmpty)
        let bad = try parse("[appearance]\ncontrast = 140")
        #expect(bad.config.appearance.contrast == 50)
        #expect(bad.issues.count == 1)
    }
}

@Suite struct SearchScopeTests {
    let scopes = SearchScope.builtIn + [.plugin(id: "github", name: "GitHub")]

    @Test func namedByIdAliasOrPrefix() {
        #expect(SearchScope.named("clip", among: scopes) == .clipboard)
        #expect(SearchScope.named("Clipboard", among: scopes) == .clipboard)
        #expect(SearchScope.named("proj", among: scopes) == .projects)
        #expect(SearchScope.named("github", among: scopes) == .plugin(id: "github", name: "GitHub"))
        #expect(SearchScope.named("kube", among: scopes) == nil)
        #expect(SearchScope.named("sn", among: scopes) == nil) // too short to guess
    }

    @Test func tabCyclesAndWraps() {
        #expect(SearchScope.next(after: nil, in: scopes) == .apps)
        #expect(SearchScope.next(after: .apps, in: scopes) == .files)
        #expect(SearchScope.next(after: .plugin(id: "github", name: "GitHub"), in: scopes) == nil)
        #expect(SearchScope.next(after: nil, in: scopes, backwards: true) == .plugin(id: "github", name: "GitHub"))
        #expect(SearchScope.next(after: .apps, in: scopes, backwards: true) == nil)
    }

    @Test func yourOrderComesFirst() {
        let gh = SearchScope.plugin(id: "github", name: "GitHub")
        let mine = SearchScope.ordered(scopes, by: ["clipboard", "github", "nope", "clip"])
        #expect(mine.prefix(2) == [.clipboard, gh])
        #expect(mine.count == scopes.count) // the rest follow; unknown names and repeats are skipped
        #expect(mine.dropFirst(2) == ArraySlice(scopes.filter { $0 != .clipboard && $0 != gh }))
        #expect(SearchScope.next(after: nil, in: mine) == .clipboard) // ⇥ goes there first
        #expect(SearchScope.ordered(scopes, by: []) == scopes)
        let hidden = SearchScope.ordered(scopes, by: ["history"], hidden: ["History", "apps"])
        #expect(!hidden.contains(.history) && !hidden.contains(.apps))
        #expect(hidden.count == scopes.count - 2)
    }

    @Test func sourcesInConfig() throws {
        let c = try ConfigLoader.parse("[search]\nsources = [\"Clipboard\", \"apps\"]\nhidden = [\"history\"]\n")
        #expect(c.config.sourceOrder == ["clipboard", "apps"])
        #expect(c.config.hiddenSources == ["history"])
        #expect(c.issues.isEmpty)
        #expect(try ConfigLoader.parse(DefaultConfig.text).config.sourceOrder == [])
    }

    @Test func draggingWritesTheList() throws {
        // Added under [search], keeping everything else.
        let added = try #require(ConfigEditor.set("sources", to: ["clipboard", "apps"], in: "search", text: DefaultConfig.text))
        #expect(try ConfigLoader.parse(added).config.sourceOrder == ["clipboard", "apps"])
        #expect(added.components(separatedBy: "\n").count == DefaultConfig.text.components(separatedBy: "\n").count + 1)
        // Then replaced in place, comment kept.
        let one = "[search]\nsources = [\"apps\", \"files\"]  # mine\nfavorites = []\n"
        #expect(ConfigEditor.set("sources", to: ["files", "apps"], in: "search", text: one)
                == "[search]\nsources = [\"files\", \"apps\"]  # mine\nfavorites = []\n")
        // A list over several lines (with a ] in a string and a comment) becomes one line.
        let multi = "[search]\nsources = [\n  \"apps\", # first\n  \"we]ird\",\n]\nfavorites = []\n"
        #expect(ConfigEditor.set("sources", to: ["clipboard"], in: "search", text: multi)
                == "[search]\nsources = [\"clipboard\"]\nfavorites = []\n")
        // Quotes in a plugin id survive.
        let odd = try #require(ConfigEditor.set("sources", to: ["a\"b\\c"], in: "search", text: ""))
        #expect(try ConfigLoader.parse(odd).config.sourceOrder == ["a\"b\\c"])
    }

    @Test func typedPrefixes() {
        let p = ["c": "clipboard", "gh": "github"]
        #expect(SearchScope.prefixed("c kube", prefixes: p, among: scopes)! == (.clipboard, "kube"))
        #expect(SearchScope.prefixed("gh filters", prefixes: p, among: scopes)! == (.plugin(id: "github", name: "GitHub"), "filters"))
        #expect(SearchScope.prefixed("cat file", prefixes: p, among: scopes) == nil)
        #expect(SearchScope.prefixed("c", prefixes: p, among: scopes) == nil)
    }

    @Test func scopesConfig() throws {
        let dir = URL(fileURLWithPath: "/home/me/.config/euclid")
        let c = try ConfigLoader.parse("[search]\nscopes = { c = \"Clipboard\", f = \"files\" }", directory: dir,
                                       fileExists: { _ in true }, readFile: { _ in nil })
        #expect(c.config.scopePrefixes == ["c": "clipboard", "f": "files"])
        #expect(c.issues.isEmpty)
    }
}

@Suite struct TipsAndCheatSheetTests {
    @Test func tipsRotateAndRetire() {
        let first = Tips.pick(opens: 0, used: [])
        #expect(first == Tips.all[0])
        #expect(Tips.pick(opens: 1, used: []) == Tips.all[1])
        #expect(Tips.pick(opens: 0, used: ["answers"]) == Tips.all[1])
        #expect(Tips.pick(opens: 3, used: Set(Tips.all.map(\.feature))) == nil)
    }

    @Test func cheatSheetListsEverything() {
        let text = CheatSheet.text(scopes: [.apps, .clipboard, .plugin(id: "github", name: "GitHub")], prefixes: ["c": "clipboard"],
                                   actions: ["Search web", "pi in Ghostty"], aliases: [("code", "Visual Studio Code")],
                                   snippets: [("standup", "Standup notes")], pluginKeys: [("⌘G", "GitHub Desktop")])
        for needle in ["⌘K", "⌘/", "clipboard ⇥  or  c …", "github ⇥", "⌘1", "Search web", "code", "standup", "⌘G", "#7c5cff"] {
            #expect(text.contains(needle), "\(needle)")
        }
        // Columns line up.
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("⌘K ") || $0.hasPrefix("⌘/ ") }
        #expect(lines.count == 2)
    }
}
