import Foundation
import Testing
@testable import EuclidCore

@Suite struct SettingsGuideTests {
    let current = """
        hotkey = "opt+space"

        [appearance]
        theme = "default"   # look
        density = "comfortable"

        """

    /// A config folder with `current` in it.
    func folder(_ config: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (config ?? current).write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        return dir
    }

    func rejection(_ reply: String, in dir: URL) -> SettingsChange.Rejection? {
        if case .failure(let r) = SettingsChange.review(reply, directory: dir) { return r }
        return nil
    }

    // MARK: Finding files

    @Test func unnamedReplyIsConfigToml() {
        let reply = """
            Here you go:

            ```toml
            [appearance]
            theme = "nord"
            ```

            Run this after:
            ```
            x
            ```
            I changed the theme to Nord.
            """
        let files = SettingsChange.files(in: reply)
        #expect(files.count == 1)
        #expect(files[0].path == "config.toml")
        #expect(files[0].text == "[appearance]\ntheme = \"nord\"\n")
        #expect(SettingsChange.files(in: "  theme = 1\n\n").first?.text == "  theme = 1\n") // just the file, no fence
        #expect(SettingsChange.files(in: "```toml\nhotkey = \"opt+space\"").first?.text == "hotkey = \"opt+space\"\n") // cut off
        #expect(SettingsChange.files(in: " \n ").isEmpty)
    }

    @Test func namedBlocksAreTheirFiles() {
        let reply = """
            File: `config.toml`
            ```toml
            hotkey = "opt+space"
            ```

            **File:** `plugins/weather/plugin.toml`
            ```toml
            name = "Weather"
            ```

            ### ~/.config/euclid/plugins/weather/now.sh
            ```bash
            #!/bin/zsh
            curl -s wttr.in
            ```

            Here's your new `bin/hello`:
            ```
            #!/bin/sh
            echo hi
            ```
            ```
            not named: ignored
            ```
            """
        let files = SettingsChange.files(in: reply)
        #expect(files.map(\.path) == ["config.toml", "plugins/weather/plugin.toml", "plugins/weather/now.sh", "bin/hello"])
        #expect(files[2].text == "#!/bin/zsh\ncurl -s wttr.in\n")
    }

    @Test func onlyWritesInsideTheSettings() {
        for ok in ["config.toml", "plugins/jira/plugin.toml", "plugins/jira/lib/x.sh", "bin/ghostty-run", "themes/mine.toml"] {
            #expect(SettingsChange.isAllowed(ok), "\(ok)")
        }
        for bad in ["/etc/hosts", "../.zshrc", "plugins/../../x", "bin/../config.toml", "~/x", "AGENTS.md", "plugins/AGENTS.md",
                    "plugins/x/AGENTS.md", "plugins/x", "bin/sub/x", "themes/x.sh", ".git/config", "config.toml/x", "plugins/a b/c"] {
            #expect(!SettingsChange.isAllowed(bad), "\(bad)")
        }
    }

    // MARK: Checking

    @Test func reviewListsChangedSettings() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reply = "```toml\n" + current.replacingOccurrences(of: #""default""#, with: #""nord""#) + "```\nDone."
        let review = try SettingsChange.review(reply, directory: dir).get()
        #expect(review.files.count == 1)
        #expect(review.files[0].removed == [#"theme = "default"   # look"#])
        #expect(review.files[0].added == [#"theme = "nord"   # look"#])
        #expect(!review.files[0].isScript && !review.files[0].isNew)
        #expect(!review.looksPartial)
    }

    @Test func reviewRejectsWhatCantBeApplied() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(rejection("", in: dir) == .empty)
        #expect(rejection("```toml\n\(current)```", in: dir) == .unchanged)
        #expect(rejection("File: `../.zshrc`\n```\nrm -rf ~\n```", in: dir) == .notAllowed(["../.zshrc"]))
        guard case .problems(let p) = rejection("Sure! [appearance theme = nord", in: dir) else { Issue.record("prose isn't TOML"); return }
        #expect(p[0].hasPrefix("config.toml isn't valid TOML"))
        guard case .problems(let unknown) = rejection(current + "nonsense = true\n", in: dir) else { Issue.record("unknown key"); return }
        #expect(unknown.count == 1 && unknown[0].contains("nonsense"))
        #expect(SettingsGuide.fixPrompt(unknown).contains("nonsense"))
    }

    @Test func problemsTheFileAlreadyHasDontBlock() throws {
        let broken = current + "bogus = 1\n"
        let dir = try folder(broken)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SettingsChange.problems(in: dir).count == 1)
        let review = try SettingsChange.review(broken.replacingOccurrences(of: "comfortable", with: "compact"), directory: dir).get()
        #expect(review.files.count == 1)
    }

    @Test func brokenPluginBlocksTheWholeReply() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reply = """
            File: `config.toml`
            ```toml
            \(current.replacingOccurrences(of: "comfortable", with: "compact"))```
            File: `plugins/weather/plugin.toml`
            ```toml
            name = "Weather"
            [source
            ```
            """
        guard case .problems(let p) = rejection(reply, in: dir) else { Issue.record("broken plugin.toml"); return }
        #expect(p.contains { $0.contains("plugin.toml isn't valid TOML") })
        #expect(!p.contains { $0.contains("euclid-check-") }) // scratch paths never shown
        // Nothing was written.
        #expect(try String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8) == current)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("plugins").path))
    }

    @Test func flagsAReplyWithOnlyTheChangedPart() throws {
        let dir = try folder(DefaultConfig.text)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try SettingsChange.review("[appearance]\ntheme = \"nord\"\n", directory: dir).get().looksPartial)
    }

    // MARK: Writing, Undo, Restore

    @Test func applyThenRestorePutsEverythingBack() throws {
        let dir = try folder()
        let backups = dir.appendingPathComponent("backups-elsewhere")
        defer { try? FileManager.default.removeItem(at: dir) }
        let reply = """
            File: `config.toml`
            ```toml
            \(current.replacingOccurrences(of: "comfortable", with: "compact"))```
            File: `plugins/weather/plugin.toml`
            ```toml
            name = "Weather"
            [source]
            run = "./now.sh"
            ```
            File: `plugins/weather/now.sh`
            ```sh
            #!/bin/zsh
            echo '{"title":"Sunny"}'
            ```
            """
        let review = try SettingsChange.review(reply, directory: dir).get()
        #expect(review.files.map(\.isNew) == [false, true, true])
        #expect(review.files[2].isScript)
        let backup = try SettingsChange.apply(review, directory: dir, backups: backups)
        let script = dir.appendingPathComponent("plugins/weather/now.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        #expect(try String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8).contains("compact"))
        #expect(SettingsChange.latestBackup(in: backups)?.lastPathComponent == backup.lastPathComponent)

        try SettingsChange.restore(backup, directory: dir)
        #expect(try String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8) == current)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("plugins/weather").path))
        #expect(SettingsChange.latestBackup(in: backups) == nil)
    }

    @Test func applyKeepsASymlinkedConfig() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles.toml")
        let link = dir.appendingPathComponent("config.toml")
        try FileManager.default.moveItem(at: link, to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let review = try SettingsChange.review(current + "[files]\nlimit = 3\n", directory: dir).get()
        _ = try SettingsChange.apply(review, directory: dir, backups: dir.appendingPathComponent("b"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("limit = 3"))
    }

    // MARK: Prompts and guide

    @Test func promptHasRulesFileAndReference() {
        let p = SettingsGuide.prompt(current: current)
        #expect(p.contains("File: `config.toml`"))
        #expect(p.contains("Copy Plugin Guide for AI"))
        #expect(p.contains(current.dropLast()))
        #expect(p.contains(DefaultConfig.text))
        #expect(p.hasSuffix("## What I want\n"))
        // The default file already is the reference: don't send it twice.
        let fresh = SettingsGuide.prompt(current: DefaultConfig.text)
        #expect(fresh.components(separatedBy: "[clipboard]").count == 2)
        // Short enough for chats that cap a prompt's length (Copilot), for a default setup.
        #expect(fresh.count < 12_000)
        #expect(SettingsGuide.pluginPrompt(guide: PluginGuide.guide).contains("## plugin.toml"))
        #expect(!SettingsGuide.pluginPrompt(guide: PluginGuide.guide).contains(PluginGuide.marker))
    }

    @Test func guideIsInstalledButNeverOverYours() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SettingsGuide.install(in: dir)
        let url = dir.appendingPathComponent("AGENTS.md")
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == SettingsGuide.guide)
        #expect(written.contains("--check-config") && written.contains("plugins/AGENTS.md"))
        try "my notes".write(to: url, atomically: true, encoding: .utf8)
        try SettingsGuide.install(in: dir)
        #expect(try String(contentsOf: url, encoding: .utf8) == "my notes")
    }
}
