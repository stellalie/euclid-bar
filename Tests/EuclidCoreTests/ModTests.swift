import Foundation
import Testing
@testable import EuclidCore

@Suite struct ModTests {
    @Test func hooksAndKeysParse() throws {
        var issues: [ConfigIssue] = []
        let p = try #require(PluginLoader.parse("""
            name = "Links"
            [[on]]
            event = "clipboard"
            run = "./clean.sh"
            [[on]]
            event = "Open"
            run = "./open.sh"
            [[key]]
            key = "cmd+g"
            name = "Open in GitHub Desktop"
            when = ["pr", "project"]
            run = 'open -a "GitHub Desktop" "$1"'
            [[key]]
            key = "ctrl+opt+r"
            when = "file"
            run = 'open -R "$1"'
            """, id: "links", directory: "/tmp/links", &issues))
        #expect(issues.isEmpty, "\(issues)")
        #expect(p.hooks == [.init(event: .clipboard, run: "./clean.sh"), .init(event: .open, run: "./open.sh")])
        #expect(p.keys.map(\.key.symbols) == ["⌘G", "⌃⌥R"])
        #expect(p.keys[0].when == ["pr", "project"] && p.keys[1].when == ["file"])
        #expect(p.keys[1].name == "Links") // defaults to the plugin's name
    }

    @Test func badHooksAndKeysAreReported() {
        var issues: [ConfigIssue] = []
        let p = PluginLoader.parse("""
            [[on]]
            event = "boot"
            run = "./x.sh"
            [[key]]
            key = "g"
            run = "x"
            [[key]]
            key = "cmd+k"
            run = "x"
            [[key]]
            key = "cmd+shift+r"
            """, id: "bad", directory: "/tmp/bad", &issues)
        #expect(p?.hooks.isEmpty == true && p?.keys.isEmpty == true)
        #expect(issues.map(\.message) == [
            "on #1: event must be one of clipboard, open, choose, app",
            "key #1: key: 'g' needs a modifier, or it would block normal typing",
            "key #2: ⌘K is Euclid's actions; pick another key",
            "key #3.run must be a command, e.g. './items.sh'",
            "has no [source], [answer], [badge], [[action]], [[on]] or [[key]], so it does nothing",
        ])
    }

    @Test func keysApplyByKindOrPlugin() throws {
        let spec = try HotkeySpec.parse("cmd+g").get()
        let key = Plugin.Key(key: spec, name: "x", run: "x", when: ["pr", "github"])
        #expect(key.applies(to: ModItem(kind: "pr", title: "Fix")))
        #expect(key.applies(to: ModItem(kind: "plugin", title: "Fix", pluginID: "github")))
        #expect(!key.applies(to: ModItem(kind: "file", title: "a.txt")))
        #expect(Plugin.Key(key: spec, name: "x", run: "x", when: []).applies(to: ModItem(kind: "file", title: "a")))
    }

    @Test func effects() {
        let out = Data("""
            cleaning…
            {"notice":"Cleaned","copy":"https://x"}
            {"open":"/tmp"}
            {"nothing":"here"}
            {broken
            {"query":"jira "}
            """.utf8)
        #expect(PluginEffect.parse(out) == [.init(notice: "Cleaned", copy: "https://x"), .init(open: "/tmp"), .init(query: "jira ")])
    }

    @Test func itemEnvironment() {
        let item = ModItem(kind: "file", title: "notes.md", subtitle: "~/notes", path: "/Users/me/notes.md")
        #expect(item.value == "/Users/me/notes.md")
        #expect(item.environment["EUCLID_ITEM_KIND"] == "file")
        #expect(item.environment["EUCLID_ITEM_PATH"] == "/Users/me/notes.md")
        #expect(item.environment["EUCLID_ITEM_URL"] == nil)
        #expect(ModItem(kind: "app", title: "Safari").value == "Safari")
    }

    @Test func trialRunsHooksWithSampleText() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-trial-\(UUID().uuidString)")
        let folder = dir.appendingPathComponent("cleanlinks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try PluginGuide.installExample("cleanlinks", in: dir)
        var issues: [ConfigIssue] = []
        let manifest = try String(contentsOf: folder.appendingPathComponent("plugin.toml"), encoding: .utf8)
        let p = try #require(PluginLoader.parse(manifest, id: "cleanlinks", directory: folder.path, &issues))
        let (report, ok) = await PluginTrial.run(p, query: "https://ex.com/a?utm_source=x&id=3#top", shell: "/bin/zsh", pathPrefix: nil)
        #expect(ok, "\(report)")
        #expect(report.contains(#"copy “https://ex.com/a?id=3#top”, notice “Cleaned a tracking link”"#) || report.contains("notice “Cleaned a tracking link”, copy “https://ex.com/a?id=3#top”"), "\(report)")
        let (quiet, _) = await PluginTrial.run(p, query: "https://ex.com/a?id=3", shell: "/bin/zsh", pathPrefix: nil)
        #expect(quiet.contains("no effects"))
    }
}
