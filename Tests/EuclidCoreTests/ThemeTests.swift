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
            let light: Set = ["catppuccin-latte", "paper", "glacier", "matcha", "sakura", "sandstone"]
            #expect(p.mode == (name.hasSuffix("-light") || light.contains(name) ? .light : .dark), "\(name)")
        }
        #expect(Themes.names.first == "default")
    }

    /// WCAG contrast: body text at least 7:1 (AAA), the accent ring and caret at least 3:1 (UI parts).
    @Test func everyBuiltInIsReadable() {
        func luminance(_ hex: String) -> Double {
            let c = Appearance.parseHex(hex)!
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        func ratio(_ a: String, _ b: String) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for (name, p) in Themes.builtIn where ["aurora", "neon-noir", "ember", "velvet", "phosphor", "amber", "graphite",
                                               "paper", "glacier", "matcha", "sakura", "sandstone"].contains(name) {
            #expect(ratio(p.text, p.background) >= 7, "\(name) text")
            #expect(ratio(p.accent, p.background) >= 3, "\(name) accent")
        }
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
