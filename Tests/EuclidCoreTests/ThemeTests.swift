import Foundation
import Testing
@testable import EuclidCore

@Suite struct ThemeTests {
    let dir = URL(fileURLWithPath: "/home/me/.config/euclid")

    func parse(_ text: String, files: [String: String] = [:]) throws -> LoadedConfig {
        try ConfigLoader.parse(text, directory: dir, fileExists: { _ in true }, readFile: { files[$0] })
    }

    @Test func defaultIsTheSystemLook() throws {
        let c = try parse("")
        #expect(c.config.appearance.theme == "default")
        #expect(c.config.appearance.palette == nil)
        #expect(c.issues.isEmpty)
        #expect(c.themeFiles.isEmpty) // nothing read, nothing watched
    }

    @Test func builtInWithOverrides() throws {
        let c = try parse("""
            [appearance]
            theme = "nord"
            accent = "#ff8a3d"
            density = "compact"
            """)
        let a = c.config.appearance
        #expect(a.palette == Themes.builtIn["nord"])
        #expect(a.palette?.mode == .dark)
        #expect(a.accent == "#ff8a3d") // still wins over the theme's accent in the app
        #expect(a.density == .compact)
        #expect(c.issues.isEmpty)
    }

    @Test func everyBuiltInIsComplete() {
        for (name, p) in Themes.builtIn {
            let hexes = [p.background, p.text, p.accent, p.subtext, p.muted, p.selection, p.border].compactMap { $0 } + p.colors.values
            #expect(hexes.allSatisfy { Appearance.parseHex($0) != nil }, "\(name)")
            #expect(Set(p.colors.keys) == Set(ThemePalette.colorNames), "\(name)")
            #expect(p.mode == (name.hasSuffix("-light") || name == "catppuccin-latte" ? .light : .dark), "\(name)")
        }
        #expect(Themes.names.first == "default")
    }

    @Test func unknownThemeWarnsAndFallsBack() throws {
        let c = try parse("[appearance]\ntheme = \"vaporwave\"")
        #expect(c.config.appearance.palette == nil)
        #expect(c.issues.count == 1)
        #expect(c.issues[0].message.contains("dracula"))
    }

    @Test func themeFile() throws {
        let c = try parse("[appearance]\ntheme = \"mine\"", files: ["/home/me/.config/euclid/themes/mine.toml": """
            background = "#fafafa"
            text = "#111111"
            accent = "#0a84ff"
            green = "#00aa00"
            opacity = 1
            """])
        let p = try #require(c.config.appearance.palette)
        #expect(p.mode == .light) // from the background
        #expect(p.background == "#fafafa" && p.text == "#111111" && p.accent == "#0a84ff")
        #expect(p.subtext == nil && p.selection == nil)
        #expect(p.colors == ["green": "#00aa00"])
        #expect(p.opacity == 1)
        #expect(c.issues.isEmpty)
        #expect(c.themeFiles == ["/home/me/.config/euclid/themes", "/home/me/.config/euclid/themes/mine.toml"])
    }

    @Test func themeFileFromABase() throws {
        let c = try parse("[appearance]\ntheme = \"dracula\"", files: ["/home/me/.config/euclid/themes/dracula.toml": """
            base = "dracula"
            accent = "#ff79c6"
            """])
        var expected = Themes.builtIn["dracula"]!
        expected.accent = "#ff79c6"
        #expect(c.config.appearance.palette == expected) // the file wins over the built-in
        #expect(c.issues.isEmpty)
    }

    @Test func badThemeFileWarns() throws {
        let c = try parse("[appearance]\ntheme = \"mine\"", files: ["/home/me/.config/euclid/themes/mine.toml": """
            background = "dark blue"
            text = "#fff"
            colour = "#fff"
            """])
        #expect(c.config.appearance.palette == nil)
        // bad background, unknown key, missing required colours
        #expect(c.issues.count == 3)
    }
}
