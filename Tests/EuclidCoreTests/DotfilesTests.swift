import Foundation
import Testing
@testable import EuclidCore

/// ~/.config/euclid is meant to live in a dotfiles repo: config.local.toml for one Mac, a .gitignore.
@Suite struct DotfilesTests {
    let dir = URL(fileURLWithPath: "/home/me/.config/euclid")

    func parse(_ text: String, local: String?, team: String? = nil) throws -> LoadedConfig {
        try ConfigLoader.parse(text, directory: dir, local: local,
                               readFile: { $0 == "/home/me/.config/euclid/team.toml" ? team : nil })
    }

    @Test func localWinsOverConfig() throws {
        let loaded = try parse("""
            include = "team.toml"
            hotkey = "opt+space"
            [env]
            WHERE = "everywhere"
            KEEP = "yes"
            [[action]]
            name = "Mine"
            run = 'echo mine'
            [[action]]
            name = "Deploy"
            run = 'echo home'
            [hotkeys]
            Deploy = "ctrl+opt+d"
            """, local: """
            hotkey = "cmd+space"
            [env]
            WHERE = "work"
            [[action]]
            name = "Deploy"
            run = 'echo work'
            [[action]]
            name = "VPN"
            run = 'echo vpn'
            [hotkeys]
            Deploy = "ctrl+opt+v"
            """, team: """
            [[action]]
            name = "Team"
            run = 'echo team'
            """)
        let c = loaded.config
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.includedFiles == ["/home/me/.config/euclid/team.toml", "/home/me/.config/euclid/config.local.toml"])
        #expect(c.hotkey == HotkeySpec(modifiers: [.command], key: "space"))
        #expect(c.environment == ["WHERE": "work", "KEEP": "yes"])
        // This Mac's first, then yours (same name replaced), then the team's.
        #expect(c.actions.map(\.name) == ["Deploy", "VPN", "Mine", "Team"])
        #expect(c.actions[0].run == "echo work")
        #expect(c.commandHotkeys.map(\.hotkey.symbols) == ["⌃⌥V"])
    }

    @Test func noLocalFileChangesNothing() throws {
        let loaded = try parse("[[action]]\nname = \"Mine\"\nrun = 'echo'", local: nil)
        #expect(loaded.issues.isEmpty)
        #expect(loaded.includedFiles.isEmpty)
        #expect(loaded.config.actions.map(\.name) == ["Mine"])
    }

    @Test func brokenLocalFileIsAWarning() throws {
        let loaded = try parse("[[action]]\nname = \"Mine\"\nrun = 'echo'", local: "this = = not toml")
        #expect(loaded.issues.map(\.message) == ["config.local.toml isn't valid TOML, skipped"])
        #expect(loaded.config.actions.map(\.name) == ["Mine"])
        let nested = try parse("", local: "include = \"x.toml\"\n[files]\nlimit = 0")
        #expect(nested.issues.map(\.message) == ["config.local.toml: include only works in config.toml, not in an included file",
                                                 "config.local.toml: files.limit must be a number from 1 to 30"])
    }

    @Test func loadOrCreateReadsTheLocalFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "hotkey = \"opt+space\"".write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "hotkey = \"cmd+k\"".write(to: folder.appendingPathComponent("config.local.toml"), atomically: true, encoding: .utf8)
        let loaded = try ConfigLoader.loadOrCreate(at: folder.appendingPathComponent("config.toml"))
        #expect(loaded.config.hotkey.key == "k")
        #expect(loaded.includedFiles == [folder.appendingPathComponent("config.local.toml").path])
    }

    @Test func gitignoreIsWrittenOnceAndKeepsYours() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-dotfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ConfigLoader.installGitignore(in: folder)
        let file = folder.appendingPathComponent(".gitignore")
        let text = try String(contentsOf: file, encoding: .utf8)
        let rules = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(rules == ["config.local.toml", "plugins/AGENTS.md", ".DS_Store"])
        try "mine\n".write(to: file, atomically: true, encoding: .utf8)
        try ConfigLoader.installGitignore(in: folder)
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine\n")
    }

    @Test func hotkeyDefaultsWhenUnset() throws {
        #expect(try ConfigLoader.parse("").config.hotkey == HotkeySpec(modifiers: [.option], key: "space"))
    }
}
