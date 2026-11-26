import Foundation
import Testing
@testable import EuclidCore

/// `euclid-bar --theme`: list and switch themes from a shell.
@Suite struct ThemeCommandTests {
    let config = """
        hotkey = "opt+space"

        [appearance]
        theme = "nord"     # my favourite
        density = "compact"
        """

    @Test func listsBuiltInsAndYoursWithTheCurrentMarked() {
        let r = ThemeCommand.run([], configText: config, current: "nord", yourThemes: ["midnight"])
        #expect(r.status == 0 && r.newText == nil)
        let lines = r.output.components(separatedBy: "\n")
        #expect(lines.first == "  default")
        #expect(lines.contains("* nord"))
        #expect(lines.contains("  dracula"))
        #expect(lines.contains("  midnight  (themes/midnight.toml)"))
    }

    @Test func switchingKeepsTheRestOfTheFile() throws {
        let r = ThemeCommand.run(["dracula"], configText: config, current: "nord", yourThemes: [])
        #expect(r.status == 0)
        #expect(r.output == "theme: dracula")
        let text = try #require(r.newText)
        #expect(text.contains(#"theme = "dracula"  # my favourite"#)) // its comment stays, in its column
        #expect(text.contains(#"density = "compact""#))
        #expect(text.hasPrefix(#"hotkey = "opt+space""#))

        // No [appearance] yet: it's added.
        let added = try #require(ThemeCommand.run(["nord"], configText: #"hotkey = "opt+space""#, current: "default", yourThemes: []).newText)
        #expect(added.contains("[appearance]") && added.contains(#"theme = "nord""#))
    }

    @Test func unknownOrSameSaysSoAndWritesNothing() {
        let unknown = ThemeCommand.run(["solar"], configText: config, current: "nord", yourThemes: [])
        #expect(unknown.status == 64 && unknown.newText == nil)
        #expect(unknown.output.hasPrefix("error: no theme 'solar': did you mean solarized-dark, solarized-light?"))
        let same = ThemeCommand.run(["nord"], configText: config, current: "nord", yourThemes: [])
        #expect(same.newText == nil && same.output == "theme: nord (already)")
        let yours = ThemeCommand.run(["midnight"], configText: config, current: "nord", yourThemes: ["midnight"])
        #expect(yours.newText?.contains(#"theme = "midnight""#) == true)
    }
}
