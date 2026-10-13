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
        output = "panel"

        [[action]]
        name = "Old ghostty"
        run = "pi"
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
        #expect(messages.contains("use run = 'ghostty-run tab <command>'"))
    }

    @Test func envTable() throws {
        let toml = """
        [env]
        AWS_PROFILE = "dev"
        AWS_REGION = "us-east-1"
        "BAD-NAME" = "x"
        NUM = 3
        """
        let loaded = try ConfigLoader.parse(toml)
        #expect(loaded.config.environment == ["AWS_PROFILE": "dev", "AWS_REGION": "us-east-1"])
        #expect(loaded.issues.count == 2)
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

    /// The login profile reorders PATH; scripts in the bin dir must still win.
    @Test func binDirectoryWinsOverLoginProfilePath() async throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let shadow = bin.appendingPathComponent("ls") // collides with /bin/ls
        try "#!/bin/sh\necho fake\n".write(to: shadow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shadow.path)
        let p = CommandRunner.makeProcess(shell: "/bin/zsh", command: "command -v ls", query: "",
                                          pathPrefix: bin.path, baseEnvironment: ["HOME": NSHomeDirectory()])
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(found.trimmingCharacters(in: .whitespacesAndNewlines) == shadow.path)
    }

    @Test func urlEncodingIsStrict() {
        #expect(CommandRunner.urlEncode("a b&c=d/é+#") == "a%20b%26c%3Dd%2F%C3%A9%2B%23")
    }

    /// Full chain for `run = 'ghostty-run tab printf "%s" "$1"'`:
    /// Euclid → login shell → ghostty-run (dry run: prints what Ghostty would get)
    /// → `/bin/sh -c <command>` with EUCLID_CMD in env, exactly like Ghostty.
    @Test func ghosttyRunScriptKeepsQueryInert() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin")
        try ConfigLoader.installDefaultScripts(in: bin)
        let pwned = dir.appendingPathComponent("pwned").path
        let out = dir.appendingPathComponent("out").path
        let evil = "it's \"q\" $(touch \(pwned)) `touch \(pwned)` a\\b\nline2"

        // 1. What ghostty-run would hand to Ghostty.
        let p = CommandRunner.makeProcess(shell: "/bin/zsh", command: #"ghostty-run tab printf "%s" "$1""#, query: evil,
                                          pathPrefix: bin.path,
                                          baseEnvironment: ["HOME": NSHomeDirectory(), "GHOSTTY_RUN_DRY": "1"])
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let lines = printed.split(separator: "\n", maxSplits: 1).map(String.init)
        let termCommand = try #require(lines.first)
        let envValue = try #require(lines.last?.trimmingCharacters(in: .newlines))
        #expect(envValue.hasPrefix("EUCLID_CMD="))

        // 2. Do what Ghostty does. Swap the trailing interactive shell for a no-op.
        let g = Process()
        g.executableURL = URL(fileURLWithPath: "/bin/sh")
        g.arguments = ["-c", termCommand]
        g.environment = ["HOME": NSHomeDirectory(), "SHELL": "/usr/bin/true",
                         "EUCLID_CMD": String(envValue.dropFirst("EUCLID_CMD=".count)) + " > \(out)"]
        try g.run()
        g.waitUntilExit()
        #expect(try String(contentsOfFile: out, encoding: .utf8) == evil)
        #expect(!FileManager.default.fileExists(atPath: pwned))
    }

    @Test func installDefaultScriptsNeverOverwrites() throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bin) }
        try ConfigLoader.installDefaultScripts(in: bin)
        let script = bin.appendingPathComponent("ghostty-run")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        try "# mine".write(to: script, atomically: true, encoding: .utf8)
        try ConfigLoader.installDefaultScripts(in: bin)
        #expect(try String(contentsOf: script, encoding: .utf8) == "# mine")
    }

    /// An unmodified older version is upgraded; that's how ghostty-run v1 users get the fix.
    @Test func installDefaultScriptsUpgradesUnmodifiedOldVersions() throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bin) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("ghostty-run")
        try Self.ghosttyRunV1.write(to: script, atomically: true, encoding: .utf8)
        try ConfigLoader.installDefaultScripts(in: bin)
        #expect(try String(contentsOf: script, encoding: .utf8) == DefaultScripts.ghosttyRun)
    }

    /// The exact v1 text, from git history (commit c92f825).
    static var ghosttyRunV1: String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", #filePath.components(separatedBy: "/Tests/")[0], "show", "c92f825:Sources/EuclidCore/Config/DefaultScripts.swift"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let src = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return src.components(separatedBy: "ghosttyRun = #\"\"\"\n")[1].components(separatedBy: "\n\"\"\"#")[0]
    }

    /// herdr-run against a fake `herdr` that answers like the real CLI (JSON IDs)
    /// and, for `pane run`, types the text into a shell with the pane's --env set.
    @Test(arguments: ["tab", "split", "split-down"])
    func herdrRunScriptKeepsQueryInert(place: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin")
        try ConfigLoader.installDefaultScripts(in: bin)
        let fake = bin.appendingPathComponent("herdr")
        try #"""
        #!/bin/zsh
        state=${0:h}/../state; mkdir -p $state
        print -r -- "$*" >> $state/calls
        for a in "$@"; do [[ $a == EUCLID_CMD=* ]] && print -rn -- "${a#EUCLID_CMD=}" > $state/env; done
        case "$1 $2" in
          "tab create") print '{"result":{"root_pane":{"pane_id":"w:p1"},"tab":{"tab_id":"w:t1"}}}' ;;
          "pane split") print '{"result":{"pane":{"pane_id":"w:p2"}}}' ;;
          "pane run")   EUCLID_CMD="$(<$state/env)" /bin/zsh -c "$4" ;;
        esac
        """#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let env = ["HOME": NSHomeDirectory(), "HERDR_RUN_APP": ""]
        // Safety first: never let this test reach the user's real herdr session.
        let resolved = Pipe()
        let check = CommandRunner.makeProcess(shell: "/bin/zsh", command: "command -v herdr", query: "",
                                              pathPrefix: bin.path, baseEnvironment: env)
        check.standardOutput = resolved
        try check.run()
        check.waitUntilExit()
        let herdrPath = String(decoding: resolved.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try #require(herdrPath.trimmingCharacters(in: .whitespacesAndNewlines) == fake.path,
                     "fake herdr is shadowed by \(herdrPath); refusing to run")

        let out = dir.appendingPathComponent("out").path
        let pwned = dir.appendingPathComponent("pwned").path
        let evil = "it's \"q\" $(touch \(pwned)) `touch \(pwned)` a\\b\nline2"
        let command = #"herdr-run "#  + place + #" zsh -c 'printf "%s" "$1" > "$2"' x "$1" "# + out
        let r = await withCheckedContinuation { c in
            CommandRunner.runInBackground(shell: "/bin/zsh", command: command, query: evil, pathPrefix: bin.path,
                                          baseEnvironment: env) {
                c.resume(returning: $0)
            }
        }
        #expect(throws: Never.self) { try r.get() }
        #expect(try String(contentsOfFile: out, encoding: .utf8) == evil)
        #expect(!FileManager.default.fileExists(atPath: pwned))

        let calls = try String(contentsOf: dir.appendingPathComponent("state/calls"), encoding: .utf8)
        let first = calls.split(separator: "\n").first.map(String.init) ?? ""
        switch place {
        case "tab": #expect(first.hasPrefix("tab create --focus --label zsh"))
        case "split": #expect(first.hasPrefix("pane split --direction right --focus"))
        default: #expect(first.hasPrefix("pane split --direction down --focus"))
        }
        #expect(calls.contains("pane run w:p"))
    }
}
