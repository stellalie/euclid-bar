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

    @Test func modRequests() throws {
        #expect(ModRequest.parse("mod: make ⌘G open PRs") == .make("make ⌘G open PRs"))
        #expect(ModRequest.parse("MOD:undo") == .undo)
        #expect(ModRequest.parse("mod:") == nil)
        #expect(ModRequest.parse("modern") == nil)

        // The command line survives quotes in the request.
        let prompt = ModRequest.prompt("say \"hi\" and it's done", executable: "/Applications/euclid-bar.app/Contents/MacOS/euclid-bar")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid mods \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = ModRequest.commandLine(agent: "printf '%s|%s'", prompt: prompt, directory: dir.path) + #"; printf '|%s' "$PWD""#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", line]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == prompt + "||" + dir.path)
        #expect(prompt.contains("--try-plugin"))
    }

    @Test func undoPutsTheFolderBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("github"), withIntermediateDirectories: true)
        try "name = \"GitHub\"".write(to: dir.appendingPathComponent("github/plugin.toml"), atomically: true, encoding: .utf8)
        #expect(throws: ModHistory.Failure.self) { try ModHistory.undo(dir) }

        try ModHistory.snapshot(dir, message: "before mod: links")
        // The agent writes a mod and edits another plugin.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("links"), withIntermediateDirectories: true)
        try "name = \"Links\"".write(to: dir.appendingPathComponent("links/plugin.toml"), atomically: true, encoding: .utf8)
        try "name = \"GitHub!\"".write(to: dir.appendingPathComponent("github/plugin.toml"), atomically: true, encoding: .utf8)
        #expect(try ModHistory.undo(dir).hasPrefix("Undid the last mod"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("links").path))
        #expect(try String(contentsOf: dir.appendingPathComponent("github/plugin.toml"), encoding: .utf8) == "name = \"GitHub\"")

        // A mod that was kept (a later request snapshotted it) is undone by dropping that snapshot.
        try ModHistory.snapshot(dir, message: "before mod: second")
        try "x".write(to: dir.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try ModHistory.snapshot(dir, message: "before mod: third")
        #expect(try ModHistory.undo(dir) == "Undid “third”")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("kept.txt").path))
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
