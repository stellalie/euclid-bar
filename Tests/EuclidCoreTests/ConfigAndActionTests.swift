import Foundation
import Testing
@testable import EuclidCore

@Suite struct ConfigTests {
    @Test func defaultConfigIsValidAndClean() throws {
        let loaded = try ConfigLoader.parse(DefaultConfig.text)
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.config.hotkey == HotkeySpec(modifiers: [.option], key: "space"))
        #expect(loaded.config.actions.map(\.name) == ["Search web", "Search GitHub"])
    }

    @Test func emptyFileGivesDefaults() throws {
        let loaded = try ConfigLoader.parse("")
        #expect(loaded.config == EuclidConfig())
        #expect(loaded.issues.isEmpty)
    }

    @Test func syntaxErrorThrowsWithLineNumber() {
        #expect {
            try ConfigLoader.parse("hotkey = \"opt+space\"\n[[action]\nname = 1")
        } throws: { error in
            "\(error)".contains("Line 2") || "\(error)".contains("line 2")
        }
    }

    @Test func actionsKeepFileOrderAndSingleQuotesNeedNoEscaping() throws {
        let toml = """
        [[action]]
        name = "Ask pi"
        run  = 'pi --print "$1"'

        [[action]]
        name = "Web"
        run  = 'open "https://x.com/?q=$EUCLID_QUERY_URL"'
        output = "background"
        """
        let actions = try ConfigLoader.parse(toml).config.actions
        #expect(actions.map(\.name) == ["Ask pi", "Web"])
        #expect(actions[0].run == #"pi --print "$1""#)
    }

    @Test func badPartsAreSkippedWithWarningsNotFatal() throws {
        let toml = """
        hotkey = "space"
        colour = "blue"

        [clipboard]
        limit = 0

        [[action]]
        name = "No command"

        [[action]]
        name = "Typo output"
        run = "true"
        output = "pannel"

        [[action]]
        name = "Later"
        run = "true"
        output = "ghostty-tab"

        [[action]]
        name = "Good"
        run = "true"
        """
        let loaded = try ConfigLoader.parse(toml)
        #expect(loaded.config.actions.map(\.name) == ["Good"])
        #expect(loaded.config.hotkey == nil)
        #expect(loaded.config.clipboardLimit == 5_000)
        let messages = loaded.issues.map(\.message).joined(separator: "\n")
        #expect(messages.contains("needs a modifier"))
        #expect(messages.contains("unknown key 'colour'"))
        #expect(messages.contains("clipboard.limit"))
        #expect(messages.contains("'No command': missing run"))
        #expect(messages.contains("unknown output 'pannel'"))
        #expect(messages.contains("isn't supported yet"))
    }

    @Test func clipboardAndShellSettings() throws {
        let toml = """
        [clipboard]
        limit = 200
        ignore_apps = ["com.1password.1password"]
        [shell]
        path = "/bin/bash"
        """
        let c = try ConfigLoader.parse(toml, fileExists: { $0 == "/bin/bash" }).config
        #expect(c.clipboardLimit == 200)
        #expect(c.ignoredApps == ["com.1password.1password"])
        #expect(c.shellPath == "/bin/bash")
    }

    @Test func loadOrCreateWritesDefaultOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.toml")
        _ = try ConfigLoader.loadOrCreate(at: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == DefaultConfig.text)
        try "hotkey = \"cmd+k\"".write(to: file, atomically: true, encoding: .utf8)
        #expect(try ConfigLoader.loadOrCreate(at: file).config.hotkey?.key == "k") // not overwritten
    }

    @Test func pathsRespectOverridesAndXDG() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(EuclidPaths(environment: [:]).configFile.path == "\(home)/.config/euclid/config.toml")
        #expect(EuclidPaths(environment: ["XDG_CONFIG_HOME": "/x"]).configFile.path == "/x/euclid/config.toml")
        #expect(EuclidPaths(environment: ["EUCLID_CONFIG_DIR": "/c", "XDG_CONFIG_HOME": "/x"]).configFile.path == "/c/config.toml")
        #expect(EuclidPaths(environment: [:]).historyDatabase.path == "\(home)/Library/Application Support/Euclid/history.sqlite")
        #expect(EuclidPaths(environment: ["EUCLID_DATA_DIR": "/d"]).historyDatabase.path == "/d/history.sqlite")
    }
}

@Suite struct HotkeySpecTests {
    @Test func parsesAliasesAndSymbols() throws {
        #expect(try HotkeySpec.parse("Opt+Space").get() == HotkeySpec(modifiers: [.option], key: "space"))
        #expect(try HotkeySpec.parse("cmd + shift + K").get() == HotkeySpec(modifiers: [.command, .shift], key: "k"))
        #expect(try HotkeySpec.parse("ctrl+alt+enter").get().key == "return")
        #expect(try HotkeySpec.parse("f5").get() == HotkeySpec(modifiers: [], key: "f5"))
    }

    @Test func rejectsBadInput() {
        #expect((try? HotkeySpec.parse("f").get()) == nil)      // bare letter
        #expect((try? HotkeySpec.parse("hyper+a").get()) == nil)
        #expect((try? HotkeySpec.parse("cmd+pageup").get()) == nil)
        #expect((try? HotkeySpec.parse("").get()) == nil)
    }
}

@Suite struct CommandRunnerTests {
    func run(_ command: String, query: String, env: [String: String] = [:]) async -> Result<Void, CommandRunner.Failure> {
        var base = ProcessInfo.processInfo.environment
        base.merge(env) { $1 }
        return await withCheckedContinuation { c in
            CommandRunner.runInBackground(shell: "/bin/zsh", command: command, query: query, baseEnvironment: base) { c.resume(returning: $0) }
        }
    }

    @Test func queryCannotInjectCommands() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out").path
        let pwned = dir.appendingPathComponent("pwned").path
        let evil = #"x"; touch \#(pwned); echo "$(touch \#(pwned))`touch \#(pwned)`"#

        let r = await run(#"printf '%s|%s' "$1" "$EUCLID_QUERY" > "$OUT""#, query: evil, env: ["OUT": out])
        #expect(throws: Never.self) { try r.get() }
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "\(evil)|\(evil)")
        #expect(!FileManager.default.fileExists(atPath: pwned))
    }

    @Test func failureReportsExitAndStderr() async {
        let r = await run("echo boom >&2; exit 3", query: "")
        #expect(throws: CommandRunner.Failure(status: 3, stderr: "boom")) { try r.get() }
    }

    @Test func loginShellFindsUserPath() async {
        // Mimics a GUI launch: minimal environment, PATH must come from the login shell.
        let r = await withCheckedContinuation { c in
            CommandRunner.runInBackground(shell: "/bin/zsh", command: "command -v brew >/dev/null || command -v ls >/dev/null",
                                          query: "", baseEnvironment: ["HOME": NSHomeDirectory()]) { c.resume(returning: $0) }
        }
        #expect(throws: Never.self) { try r.get() }
    }

    @Test func urlEncodingIsStrict() {
        #expect(CommandRunner.urlEncode("a b&c=d/é+#") == "a%20b%26c%3Dd%2F%C3%A9%2B%23")
    }
}
