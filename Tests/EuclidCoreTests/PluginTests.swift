import Foundation
import Testing
@testable import EuclidCore

@Suite struct PluginTests {
    /// A config folder with `plugins/<id>/<files>`.
    func configDir(_ plugins: [String: [String: String]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-plugins-\(UUID().uuidString)")
        for (id, files) in plugins {
            let folder = dir.appendingPathComponent("plugins/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, text) in files {
                let url = folder.appendingPathComponent(name)
                try text.write(to: url, atomically: true, encoding: .utf8)
                if name.hasSuffix(".sh") { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    let github = """
        name = "GitHub"
        [source]
        run = "./items.sh"
        refresh_minutes = 5
        [[action]]
        name = "Search GitHub code"
        run = 'open "https://github.com/search?q=$EUCLID_QUERY_URL"'
        [settings]
        limit = 30
        org = "acme"
        """

    @Test func loadsPluginsWithSettingsAndActions() throws {
        let dir = try configDir(["github": ["plugin.toml": github]])
        let loaded = try ConfigLoader.parse("""
            [[action]]
            name = "Mine"
            run = 'echo "$1"'
            [plugin.github]
            limit = 50
            """, directory: dir)
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        let p = try #require(loaded.config.plugins.first)
        #expect(p.id == "github" && p.name == "GitHub")
        #expect(p.source == .init(run: "./items.sh", refreshMinutes: 5))
        #expect(p.settings == ["limit": "50", "org": "acme"]) // yours win over the plugin's defaults
        #expect(p.environment["EUCLID_SETTING_LIMIT"] == "50")
        #expect(p.environment["EUCLID_PLUGIN_DIR"] == dir.appendingPathComponent("plugins/github").path)
        // Plugin actions come after yours and run in the plugin's folder with its settings.
        #expect(loaded.config.actions.map(\.name) == ["Mine", "Search GitHub code"])
        #expect(loaded.config.actions[1].directory == p.directory)
        #expect(loaded.config.actions[1].environment["EUCLID_SETTING_ORG"] == "acme")
        #expect(loaded.pluginFiles.contains(dir.appendingPathComponent("plugins/github/plugin.toml").path))
    }

    @Test func disabledAndUnknownPlugins() throws {
        let dir = try configDir(["github": ["plugin.toml": github]])
        let loaded = try ConfigLoader.parse("""
            [plugins]
            disabled = ["github"]
            [plugin.gitlab]
            token = "x"
            """, directory: dir)
        #expect(loaded.config.plugins.isEmpty)
        #expect(loaded.config.actions.isEmpty)
        #expect(loaded.issues.map(\.message) == ["[plugin.gitlab]: no plugin named 'gitlab' is installed"])
    }

    @Test func teamPluginFolderAndFirstIdWins() throws {
        let dir = try configDir(["github": ["plugin.toml": github]])
        let team = dir.appendingPathComponent("team")
        for id in ["github", "runbooks"] {
            let folder = team.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "name = \"Team \(id)\"\n[source]\nrun = './x.sh'\n".write(to: folder.appendingPathComponent("plugin.toml"), atomically: true, encoding: .utf8)
        }
        let loaded = try ConfigLoader.parse("[plugins]\npaths = [\"team\"]", directory: dir)
        #expect(loaded.config.plugins.map(\.name) == ["GitHub", "Team runbooks"])
    }

    @Test func manifestProblemsAreReported() {
        var issues: [ConfigIssue] = []
        let p = PluginLoader.parse("""
            name = "Broken"
            colour = "red"
            [answer]
            run = "./a.sh"
            [badge]
            refresh_minutes = 0
            """, id: "broken", directory: "/tmp/broken", &issues)
        #expect(p?.answer == nil)
        #expect(p?.badge == nil)
        #expect(issues.map(\.message) == [
            "plugin.toml: unknown key 'colour'",
            "[answer] needs a prefix or a match, so it doesn't run on every search; skipped",
            "badge.refresh_minutes must be a number from 1 to 1440",
            "badge.run must be a command, e.g. './items.sh'",
            "has no [source], [answer], [badge] or [[action]], so it does nothing",
        ])
        var bad: [ConfigIssue] = []
        #expect(PluginLoader.parse("name = ", id: "x", directory: "/x", &bad) == nil)
        #expect(bad.first?.message.hasPrefix("plugin.toml isn't valid TOML") == true)
    }

    @Test func answerTriggers() {
        let prefix = Plugin.Answer(run: "x", prefix: "tz", match: nil)
        #expect(prefix.input(for: "tz 3pm pst") == "3pm pst")
        #expect(prefix.input(for: "TZ  3pm") == "3pm")
        #expect(prefix.input(for: "tz ") == nil)
        #expect(prefix.input(for: "tzx 3pm") == nil)
        let match = Plugin.Answer(run: "x", prefix: nil, match: #"^\d+(am|pm)$"#)
        #expect(match.input(for: "3pm") == "3pm")
        #expect(match.input(for: "3 pm") == nil)
    }

    @Test func outputParsing() {
        let data = Data("""
            {"title":"Fix login","subtitle":"acme/web · #412","open":"https://x/412","label":"Review","suggest":true}

            not json
            {"subtitle":"no title"}
            {"title":"Bad","suggest":"yes"}
            {"title":"Copy me","copy":"abc"}
            """.utf8)
        let (items, problems) = PluginOutput.parse(data)
        #expect(items.map(\.title) == ["Fix login", "Copy me"])
        #expect(items[0].suggest == true && items[0].key == "https://x/412")
        #expect(items[1].key == "Copy me")
        #expect(problems == ["line 3: not a JSON object", "line 4: missing \"title\"",
                             "line 5: a field has the wrong type (all are strings, suggest is true/false)"])
        let array = PluginOutput.parse(Data(#"[{"title":"A"},{"title":"B","open":"/tmp"}]"#.utf8))
        #expect(array.items.map(\.title) == ["A", "B"] && array.problems.isEmpty)
    }

    @Test func badgeText() {
        #expect(Plugin.Badge.text(from: Data("\n  1.2M tok · $4.10  \nmore\n".utf8)) == "1.2M tok · $4.10")
        #expect(Plugin.Badge.text(from: Data("".utf8)) == nil)
        #expect(Plugin.Badge.text(from: Data(String(repeating: "x", count: 60).utf8))?.count == 40)
    }

    func plugin(_ files: [String: String]) throws -> Plugin {
        let dir = try configDir(["p": files])
        var issues: [ConfigIssue] = []
        let p = try #require(PluginLoader.parse(files["plugin.toml"]!, id: "p", directory: dir.appendingPathComponent("plugins/p").path, &issues))
        #expect(issues.isEmpty, "\(issues)")
        return p
    }

    @Test func runnerRunsInThePluginFolderWithItsSettings() async throws {
        let p = try plugin([
            "plugin.toml": "[source]\nrun = './items.sh'\n[settings]\ngreeting = \"hi\"\n",
            "items.sh": "#!/bin/sh\nprintf '{\"title\":\"%s %s\",\"subtitle\":\"%s\"}\\n' \"$EUCLID_SETTING_GREETING\" \"$1\" \"$(basename \"$PWD\")\"\n",
        ])
        let out = try await PluginRunner.output(of: "./items.sh", plugin: p, query: "there $(rm -rf /)", shell: "/bin/zsh",
                                                pathPrefix: nil, timeout: .seconds(10))
        let items = PluginOutput.parse(out).items
        #expect(items.map(\.title) == ["hi there $(rm -rf /)"]) // the query is only ever $1
        #expect(items.first?.subtitle == "p")
    }

    @Test func runnerReportsFailuresAndTimeouts() async throws {
        let p = try plugin(["plugin.toml": "[source]\nrun = 'x'\n"])
        await #expect(throws: PluginRunner.Failure("exit 3: needs gh")) {
            try await PluginRunner.output(of: "echo 'needs gh' >&2; exit 3", plugin: p, shell: "/bin/zsh", pathPrefix: nil, timeout: .seconds(10))
        }
        let start = ContinuousClock.now
        await #expect(throws: PluginRunner.Failure.self) {
            try await PluginRunner.output(of: "sleep 5", plugin: p, shell: "/bin/zsh", pathPrefix: nil, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func trialReportsWhatTheBarWouldShow() async throws {
        let p = try plugin([
            "plugin.toml": "name = \"Demo\"\n[source]\nrun = './items.sh'\n[answer]\nrun = './say.sh'\nprefix = \"say\"\n[badge]\nrun = 'echo 42 tok'\nclick = 'open x'\n",
            "say.sh": "#!/bin/sh\nprintf '{\"title\":\"%s!\",\"copy\":\"%s\"}\\n' \"$1\" \"$EUCLID_QUERY\"\n",
            "items.sh": "#!/bin/sh\necho '{\"title\":\"One\",\"open\":\"https://one\"}'\necho oops\n",
        ])
        let (report, ok) = await PluginTrial.run(p, query: "say hello", shell: "/bin/zsh", pathPrefix: nil)
        #expect(!ok) // "oops" isn't JSON
        #expect(report.contains("source: 1 item(s)"))
        #expect(report.contains("One  ↵ open https://one"))
        #expect(report.contains("problem: line 2: not a JSON object"))
        #expect(report.contains("answer for “hello”: 1 item(s)"))
        #expect(report.contains("hello!  ↵ copy text"))
        #expect(report.contains("badge: 42 tok  (click runs: open x)"))
    }

    @Test func examplesAndGuideInstall() throws {
        let dir = try configDir([:]).appendingPathComponent("plugins")
        try PluginGuide.install(in: dir)
        let guide = dir.appendingPathComponent("AGENTS.md")
        #expect(try String(contentsOf: guide, encoding: .utf8) == PluginGuide.guide)
        try "my own notes".write(to: guide, atomically: true, encoding: .utf8)
        try PluginGuide.install(in: dir)
        #expect(try String(contentsOf: guide, encoding: .utf8) == "my own notes") // never overwrites yours

        for name in PluginGuide.examples.keys {
            let folder = try PluginGuide.installExample(name, in: dir)
            var issues: [ConfigIssue] = []
            let text = try String(contentsOf: folder.appendingPathComponent("plugin.toml"), encoding: .utf8)
            #expect(PluginLoader.parse(text, id: name, directory: folder.path, &issues) != nil)
            #expect(issues.isEmpty, "\(name): \(issues)")
            for file in PluginGuide.examples[name]! where file.executable { // valid shell, at least
                let check = Process()
                check.executableURL = URL(fileURLWithPath: "/bin/sh")
                check.arguments = ["-n", folder.appendingPathComponent(file.name).path]
                try check.run()
                check.waitUntilExit()
                #expect(check.terminationStatus == 0, "\(name)/\(file.name) isn't valid sh")
            }
        }
        #expect(throws: PluginRunner.Failure.self) { try PluginGuide.installExample("github", in: dir) }

        // The currency answer wakes on conversions, not on the calculator's units.
        var issues: [ConfigIssue] = []
        let currency = try #require(PluginLoader.parse(PluginGuide.currencyManifest, id: "currency", directory: "/x", &issues)?.answer)
        #expect(currency.input(for: "100 USD to eur") == "100 USD to eur")
        #expect(currency.input(for: "1,250.5aud in jpy") != nil)
        #expect(currency.input(for: "cur 100 usd eur") == "100 usd eur")
        #expect(currency.input(for: "1.5 gb in mb") == nil)
    }
}
