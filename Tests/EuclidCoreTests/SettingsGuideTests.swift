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

    // MARK: Prompts and guide

    @Test func promptAsksFirstAndWantsTheWholeFile() {
        let p = SettingsGuide.prompt(current: current)
        #expect(p.contains(SettingsGuide.docsURL) && p.contains(SettingsGuide.pluginGuideURL))
        #expect(p.contains("Ask me what I'd like"))
        #expect(p.contains("whole config.toml") && p.contains("Edit Config…"))
        #expect(p.contains(current.dropLast()))
        #expect(!p.contains("Apply Settings from Clipboard"))
        // Short enough for chats that cap a prompt's length (Copilot), for a default setup.
        #expect(SettingsGuide.prompt(current: DefaultConfig.text).count < 12_000)
    }

    @Test func fixPromptListsProblemsAndFile() {
        let p = SettingsGuide.fixPrompt(["line 4: density must be one of compact, comfortable"], current: current)
        #expect(p.contains("- line 4: density"))
        #expect(p.contains(current.dropLast()) && p.contains("whole config.toml"))
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
