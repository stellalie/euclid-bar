import Foundation
import Testing
@testable import EuclidCore

@Suite struct IncludeTests {
    let team = """
        hotkey = "cmd+space"
        [env]
        TEAM = "platform"
        SHARED = "team"
        [aliases]
        dash = "Team dashboard"
        [[action]]
        name = "Team dashboard"
        run = 'open https://dash.example.com'
        [[action]]
        name = "Search Bitbucket"
        run = 'open team'
        [[snippet]]
        name = "PR template"
        text = "## Why"
        [plugin.bitbucket]
        base_url = "https://bitbucket.example.com"
        """

    func parse(_ text: String, files: [String: String]) throws -> LoadedConfig {
        try ConfigLoader.parse(text, directory: URL(fileURLWithPath: "/home/me/.config/euclid"), readFile: { files[$0] })
    }

    @Test func includedFileSitsUnderYours() throws {
        let loaded = try parse("""
            include = ["team.toml"]
            [env]
            SHARED = "mine"
            [[action]]
            name = "Mine"
            run = 'echo "$1"'
            [[action]]
            name = "Search Bitbucket"
            run = 'open mine'
            """, files: ["/home/me/.config/euclid/team.toml": team])
        let c = loaded.config
        #expect(loaded.issues.map(\.message) == ["[plugin.bitbucket]: no plugin named 'bitbucket' is installed"])
        #expect(loaded.includedFiles == ["/home/me/.config/euclid/team.toml"])
        #expect(c.hotkey == HotkeySpec(modifiers: [.command], key: "space"))
        #expect(c.environment == ["TEAM": "platform", "SHARED": "mine"])
        // Yours first (⌘1 stays yours); a same-named shared action is replaced by yours.
        #expect(c.actions.map(\.name) == ["Mine", "Search Bitbucket", "Team dashboard"])
        #expect(c.actions[1].run == "open mine")
        #expect(c.snippets.map(\.name) == ["PR template"])
        #expect(c.aliases.match("dash")?.target == "Team dashboard")
        #expect(c.pluginSettings["bitbucket"]?["base_url"] == "https://bitbucket.example.com")
    }

    @Test func teamSetsTheServerYouSetTheEmail() throws {
        let files = ["/srv/team.toml": "[plugin.bitbucket]\nrepos = [\"team/app\"]\nemail = \"team@example.com\""]
        let loaded = try parse("include = \"/srv/team.toml\"\n[plugin.bitbucket]\nemail = \"me@example.com\"", files: files)
        #expect(loaded.config.pluginSettings["bitbucket"] == ["repos": "team/app", "email": "me@example.com"])
    }

    @Test func oldBitbucketAndJiraTablesCarryOverToThePlugins() throws {
        let loaded = try parse("""
            [bitbucket]
            email = "me@example.com"
            repos = ["team/app", "team/api"]
            refresh_minutes = 5
            [jira]
            base_url = "https://acme.atlassian.net"
            [plugin.jira]
            base_url = "https://new.atlassian.net"
            """, files: [:])
        #expect(loaded.config.pluginSettings["bitbucket"] == ["email": "me@example.com", "repos": "team/app team/api"])
        #expect(loaded.config.pluginSettings["jira"] == ["base_url": "https://new.atlassian.net"]) // [plugin.jira] wins
        #expect(loaded.issues.map(\.message) == [
            "[bitbucket] is now a plugin: run `euclid-bar --plugin add bitbucket` (your settings carry over), then rename the table to [plugin.bitbucket]",
            "[jira] is now a plugin: run `euclid-bar --plugin add jira` (your settings carry over), then rename the table to [plugin.jira]",
        ])
    }

    @Test func badIncludesAreWarningsNotFatal() throws {
        let loaded = try parse("""
            include = ["missing.toml", "~/broken.toml", "/srv/nested.toml"]
            [[action]]
            name = "Mine"
            run = 'echo'
            """, files: [
                NSString("~/broken.toml").expandingTildeInPath: "this is = = not toml",
                "/srv/nested.toml": "include = \"x.toml\"\n[files]\nlimit = 999",
            ])
        let messages = loaded.issues.map(\.message)
        #expect(messages.contains("include: can't read 'missing.toml', skipped"))
        #expect(messages.contains("include: '~/broken.toml' isn't valid TOML, skipped"))
        #expect(messages.contains("nested.toml: include only works in config.toml, not in an included file"))
        #expect(messages.contains("nested.toml: files.limit must be a number from 1 to 30"))
        #expect(loaded.includedFiles == ["/srv/nested.toml"])
        #expect(loaded.config.actions.map(\.name) == ["Mine"])
    }

    @Test func includeMustBePaths() throws {
        let loaded = try parse("include = 3", files: [:])
        #expect(loaded.issues.map(\.message) == [#"include must be a path or a list of paths, e.g. ["~/work/team/euclid.toml"]"#])
    }

    @Test func loadOrCreateResolvesNextToConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("team"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "[[action]]\nname = \"Shared\"\nrun = 'echo'".write(to: dir.appendingPathComponent("team/euclid.toml"), atomically: true, encoding: .utf8)
        try "include = \"team/euclid.toml\"".write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let loaded = try ConfigLoader.loadOrCreate(at: dir.appendingPathComponent("config.toml"))
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.config.actions.map(\.name) == ["Shared"])
    }
}
