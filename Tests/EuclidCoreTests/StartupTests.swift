import Testing
@testable import EuclidCore

@Suite struct StartupTests {
    @Test func opensAtLoginByDefault() throws {
        #expect(EuclidConfig().openAtLogin)
        #expect(try ConfigLoader.parse(DefaultConfig.text).config.openAtLogin)
        // An older config.toml without [startup] still opens at login.
        #expect(try ConfigLoader.parse("hotkey = \"opt+space\"\n").config.openAtLogin)
    }

    @Test func parsedAndWarned() throws {
        let off = try ConfigLoader.parse("[startup]\nopen_at_login = false\n")
        #expect(!off.config.openAtLogin && off.issues.isEmpty)
        let bad = try ConfigLoader.parse("[startup]\nopen_at_login = \"no\"\nhidden = true\n")
        #expect(bad.config.openAtLogin)
        #expect(bad.issues.map(\.message) == ["[startup]: unknown key 'hidden'", "startup.open_at_login must be true or false"])
    }

    @Test func menuToggleEditsTheFile() throws {
        let edited = try #require(ConfigEditor.set("open_at_login", to: false, in: "startup", text: DefaultConfig.text))
        #expect(!(try ConfigLoader.parse(edited).config.openAtLogin))
        // A config.toml from before [startup] gets the table added.
        let old = try #require(ConfigEditor.set("open_at_login", to: false, in: "startup", text: "hotkey = \"opt+space\"\n\n[clipboard]\nlimit = 10\n"))
        let parsed = try ConfigLoader.parse(old)
        #expect(!parsed.config.openAtLogin && parsed.issues.isEmpty && parsed.config.clipboardLimit == 10)
    }
}
