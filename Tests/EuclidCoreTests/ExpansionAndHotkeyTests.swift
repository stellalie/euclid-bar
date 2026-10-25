import Foundation
import Testing
@testable import EuclidCore

@Suite struct TextExpanderTests {
    let sig = Snippet(name: "Signature", keyword: ";sig", text: "Stella")
    let standup = Snippet(name: "Standup", keyword: "standup", text: "Yesterday:")

    private func type(_ text: String, into e: inout TextExpander) -> TextExpander.Match? {
        var last: TextExpander.Match?
        for ch in text { if let m = e.typed(String(ch)) { last = m } }
        return last
    }

    @Test func symbolKeywordExpandsAsSoonAsTyped() {
        var e = TextExpander(snippets: [sig])
        #expect(e.typed(";") == nil)
        #expect(e.typed("s") == nil)
        #expect(e.typed("i") == nil)
        #expect(e.typed("g") == .init(snippet: sig, deleteCount: 4, suffix: ""))
        #expect(type("hello;sig", into: &e)?.deleteCount == 4) // mid-word too
    }

    @Test func wordKeywordWaitsForADelimiterAndAWholeWord() {
        var e = TextExpander(snippets: [standup])
        #expect(type("standup", into: &e) == nil)
        #expect(e.typed(" ") == .init(snippet: standup, deleteCount: 8, suffix: " "))
        #expect(type("standups ", into: &e) == nil)
        #expect(type("mystandup ", into: &e) == nil)
        #expect(type("so standup.", into: &e) == .init(snippet: standup, deleteCount: 8, suffix: "."))
        #expect(type("standup\t", into: &e) == nil) // tab and return act, they don't expand
    }

    @Test func backspaceAndResetFollowTheCursor() {
        var e = TextExpander(snippets: [sig])
        _ = type(";six", into: &e)
        e.deleteBackward()
        #expect(e.typed("g") != nil) // ";si" + "g"
        _ = type(";si", into: &e)
        e.reset() // clicked elsewhere
        #expect(e.typed("g") == nil)
    }

    @Test func noKeywordsNeverMatches() {
        var e = TextExpander(snippets: [Snippet(name: "x", text: "y")])
        #expect(e.isEmpty)
        #expect(type(";sig standup ", into: &e) == nil)
    }

    @Test func findsKeywordsThatCanNeverFire() {
        let s = [";s", ";sig", "a;sb", "fine", ";x"].map { Snippet(name: $0, keyword: $0, text: "t") }
        let shadowed = TextExpander.shadowedKeywords(in: s)
        #expect(shadowed.map(\.long) == [";sig", "a;sb"])
        #expect(shadowed.allSatisfy { $0.short == ";s" })
    }
}

@Suite struct CommandHotkeyConfigTests {
    private func parse(_ toml: String) throws -> LoadedConfig { try ConfigLoader.parse(toml) }

    @Test func readsHotkeysTableAndBlocks() throws {
        let loaded = try parse("""
            [hotkeys]
            Ghostty = "ctrl+opt+t"
            "euclid-bar" = "ctrl+opt+e"

            [[action]]
            name = "Search web"
            run = "open x"
            hotkey = "ctrl+opt+g"

            [[snippet]]
            name = "Sig"
            keyword = ";sig"
            text = "Stella"
            hotkey = "f5"
            """)
        #expect(loaded.issues.isEmpty)
        let hk = loaded.config.commandHotkeys
        #expect(hk.map(\.target) == ["Search web", "Sig", "Ghostty", "euclid-bar"])
        #expect(hk.map(\.kind) == [.action, .snippet, nil, nil])
        #expect(hk.map(\.hotkey.symbols) == ["⌃⌥G", "F5", "⌃⌥T", "⌃⌥E"])
    }

    @Test func skipsDuplicatesBadSpecsAndThePanelHotkey() throws {
        let loaded = try parse("""
            hotkey = "opt+space"
            [hotkeys]
            Alpha = "ctrl+opt+t"
            Beta = "opt+ctrl+t"
            Gamma = "alt+space"
            Delta = "t"
            Epsilon = 3
            """)
        #expect(loaded.config.commandHotkeys.map(\.target) == ["Alpha"])
        let messages = loaded.issues.map(\.message)
        #expect(messages.contains("hotkey ⌃⌥T is already 'Alpha', so 'Beta' skipped"))
        #expect(messages.contains("hotkey ⌥Space for 'Gamma' is the panel's hotkey, skipped"))
        #expect(messages.contains { $0.hasPrefix("hotkeys.Delta: 't' needs a modifier") })
        #expect(messages.contains("hotkeys.Epsilon must be a string like \"ctrl+opt+t\""))
    }

    @Test func yourHotkeyForSomethingReplacesTheTeams() throws {
        let team = """
            [hotkeys]
            Slack = "ctrl+opt+s"
            Mail = "ctrl+opt+m"
            """
        let loaded = try ConfigLoader.parse("""
            include = ["team.toml"]
            [hotkeys]
            Slack = "ctrl+opt+k"
            """, directory: URL(fileURLWithPath: "/x"), readFile: { _ in team })
        #expect(loaded.issues.isEmpty)
        #expect(loaded.config.commandHotkeys.map { "\($0.target) \($0.hotkey.symbols)" } == ["Slack ⌃⌥K", "Mail ⌃⌥M"])
    }

    @Test func expansionIsOptInAndWarnsAboutShadowedKeywords() throws {
        let snippets = """
            [[snippet]]
            name = "S"
            keyword = ";s"
            text = "a"
            [[snippet]]
            name = "Sig"
            keyword = ";sig"
            text = "b"
            """
        let off = try parse(snippets)
        #expect(off.config.expansionEnabled == false)
        #expect(off.issues.isEmpty)
        let on = try parse("[expansion]\nenabled = true\n" + snippets)
        #expect(on.config.expansionEnabled)
        #expect(on.issues.map(\.message) == ["snippet keyword ';sig' never expands: ';s' fires first"])
    }

    @Test func symbolsReadLikeMacMenus() {
        func sym(_ s: String) -> String? { try? HotkeySpec.parse(s).get().symbols }
        #expect(sym("cmd+shift+ctrl+opt+k") == "⌃⌥⇧⌘K")
        #expect(sym("cmd+return") == "⌘↩")
        #expect(sym("f12") == "F12")
    }
}
