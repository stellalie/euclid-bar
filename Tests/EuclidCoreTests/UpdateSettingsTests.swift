import Foundation
import Testing
@testable import EuclidCore

@Suite struct UpdateSettingsTests {
    @Test func defaultsCheckAndInstall() throws {
        #expect(try ConfigLoader.parse("").config.updates == UpdateSettings())
        #expect(UpdateSettings().check && UpdateSettings().autoInstall)
        #expect(try ConfigLoader.parse(DefaultConfig.text).config.updates == UpdateSettings())
    }

    @Test func parsesAndWarns() throws {
        let off = try ConfigLoader.parse("[updates]\nauto_install = false\n")
        #expect(off.config.updates.check && !off.config.updates.autoInstall)
        #expect(off.issues.isEmpty)

        let noCheck = try ConfigLoader.parse("[updates]\ncheck = false\n")
        #expect(!noCheck.config.updates.check && !noCheck.config.updates.autoInstall, "installing needs checking")
        #expect(noCheck.issues.isEmpty, "auto_install wasn't asked for, so nothing to warn about")

        let both = try ConfigLoader.parse("[updates]\ncheck = false\nauto_install = true\nnightly = 1\n")
        #expect(!both.config.updates.autoInstall)
        #expect(both.issues.map(\.message) == ["[updates]: unknown key 'nightly'", "updates.auto_install needs updates.check = true"])

        let bad = try ConfigLoader.parse("[updates]\ncheck = \"yes\"\n")
        #expect(bad.config.updates == UpdateSettings())
        #expect(bad.issues.map(\.message) == ["updates.check must be true or false"])
    }

    @Test func channel() throws {
        #expect(UpdateSettings().channel == .stable)
        #expect(try ConfigLoader.parse("[updates]\nchannel = \"dev\"\n").config.updates.channel == .dev)

        let bad = try ConfigLoader.parse("[updates]\nchannel = \"nightly\"\n")
        #expect(bad.config.updates.channel == .stable)
        #expect(bad.issues.map(\.message) == ["updates.channel must be \"stable\" or \"dev\""])
    }

    @Test func editorFlipsTheValueAndKeepsTheLine() throws {
        let edited = try #require(ConfigEditor.set("auto_install", to: false, in: "updates", text: DefaultConfig.text))
        #expect(edited.contains("auto_install = false             # download it in the background, install on quit"))
        #expect(try ConfigLoader.parse(edited).config.updates.autoInstall == false)
        // Only that line changed.
        let diff = zip(edited.components(separatedBy: "\n"), DefaultConfig.text.components(separatedBy: "\n")).filter { $0 != $1 }
        #expect(diff.count == 1)
        #expect(ConfigEditor.set("auto_install", to: true, in: "updates", text: edited) == DefaultConfig.text)
    }

    @Test func editorAddsTheKeyOrTheTable() throws {
        let toml = "hotkey = \"opt+space\"\n\n[updates]\ncheck = true\n\n[files]\nlimit = 3\n"
        let added = try #require(ConfigEditor.set("auto_install", to: false, in: "updates", text: toml))
        #expect(added == "hotkey = \"opt+space\"\n\n[updates]\nauto_install = false\ncheck = true\n\n[files]\nlimit = 3\n")

        // An older config.toml without [updates]: append it.
        let old = "[files]\nlimit = 3\n"
        #expect(ConfigEditor.set("auto_install", to: false, in: "updates", text: old) == "[files]\nlimit = 3\n\n[updates]\nauto_install = false\n")
        #expect(ConfigEditor.set("check", to: true, in: "updates", text: "") == "[updates]\ncheck = true\n")
        #expect(ConfigEditor.set("check", to: true, in: "updates", text: "[files]") == "[files]\n\n[updates]\ncheck = true\n")
    }

    @Test func editorIgnoresLookalikesInCommentsAndStrings() throws {
        let toml = """
        # [updates]
        # auto_install = true
        [[snippet]]
        name = "x"
        text = \"\"\"
        [updates]
        auto_install = true
        \"\"\"

        [updates]
        check = true

        """
        let edited = try #require(ConfigEditor.set("auto_install", to: false, in: "updates", text: toml))
        #expect(try ConfigLoader.parse(edited).config.snippets.first?.text == "[updates]\nauto_install = true\n")
        #expect(edited.hasSuffix("[updates]\nauto_install = false\ncheck = true\n"))
    }

    @Test func editorRefusesWhatItCantWriteSafely() {
        // An inline table can't take a [updates] header too: leave the file alone.
        #expect(ConfigEditor.set("check", to: false, in: "updates", text: "updates = { check = true }\n") == nil)
    }
}
