import Foundation
import TOMLDecoder

/// The panel's colours: `[appearance] theme = "<name>"`, from a built-in or `<config>/themes/<name>.toml`.
/// Every colour is an sRGB hex string. Optional ones fall back to a mix of the required three
/// (or, for the symbol tints, to the system colours).
public struct ThemePalette: Equatable, Sendable {
    public enum Mode: String, Sendable, CaseIterable { case dark, light }

    /// Dark or light system controls (cursor, scroller). Default: from the background's brightness.
    public var mode: Mode
    public var background: String
    /// How much of the background covers the glass or blur behind it, 0–1.
    public var opacity: Double = 0.92
    public var text: String
    public var accent: String
    /// Detail and hint text. Default: `text`, dimmer.
    public var subtext: String?
    /// Section titles and the faintest text. Default: `text`, dimmer still.
    public var muted: String?
    /// The selected row. Default: `accent`, faint.
    public var selection: String?
    /// The panel's outline. Default: `text`, faint.
    public var border: String?
    /// Symbol chip tints, by colour name: red, orange, yellow, green, cyan, blue, purple, pink.
    public var colors: [String: String] = [:]

    public static let colorNames = ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"]
    static let keys = Set(["base", "mode", "background", "opacity", "text", "accent", "subtext", "muted", "selection", "border"])
        .union(colorNames)

    public init(mode: Mode? = nil, background: String, text: String, accent: String, subtext: String? = nil, muted: String? = nil,
                selection: String? = nil, border: String? = nil, colors: [String: String] = [:]) {
        self.mode = mode ?? Self.mode(for: background)
        self.background = background
        self.text = text
        self.accent = accent
        self.subtext = subtext
        self.muted = muted
        self.selection = selection
        self.border = border
        self.colors = colors
    }

    /// Light backgrounds get light controls.
    static func mode(for background: String) -> Mode {
        guard let c = Appearance.parseHex(background) else { return .dark }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.5 ? .light : .dark
    }
}

/// Built-in themes and `<config>/themes/<name>.toml`.
public enum Themes {
    /// The system look: your accent colour, glass, light or dark with macOS.
    public static let defaultName = "default"
    public static let folderName = "themes"

    /// Palettes from popular editor colour schemes (credits in README).
    public static let builtIn: [String: ThemePalette] = [
        // Dracula, draculatheme.com (MIT)
        "dracula": ThemePalette(
            background: "#282a36", text: "#f8f8f2", accent: "#bd93f9", muted: "#6272a4", selection: "#44475a", border: "#44475a",
            colors: ["red": "#ff5555", "orange": "#ffb86c", "yellow": "#f1fa8c", "green": "#50fa7b",
                     "cyan": "#8be9fd", "blue": "#6272a4", "purple": "#bd93f9", "pink": "#ff79c6"]),
        // Nord, nordtheme.com (MIT)
        "nord": ThemePalette(
            background: "#2e3440", text: "#eceff4", accent: "#88c0d0", subtext: "#d8dee9", muted: "#616e88",
            selection: "#434c5e", border: "#3b4252",
            colors: ["red": "#bf616a", "orange": "#d08770", "yellow": "#ebcb8b", "green": "#a3be8c",
                     "cyan": "#8fbcbb", "blue": "#81a1c1", "purple": "#b48ead", "pink": "#b48ead"]),
        // Solarized by Ethan Schoonover (MIT)
        "solarized-dark": ThemePalette(
            background: "#002b36", text: "#93a1a1", accent: "#268bd2", subtext: "#839496", muted: "#586e75",
            selection: "#073642", border: "#073642", colors: solarized),
        "solarized-light": ThemePalette(
            background: "#fdf6e3", text: "#586e75", accent: "#268bd2", subtext: "#657b83", muted: "#93a1a1",
            selection: "#eee8d5", border: "#eee8d5", colors: solarized),
        // Gruvbox by Pavel Pertsev (MIT)
        "gruvbox-dark": ThemePalette(
            background: "#282828", text: "#ebdbb2", accent: "#fe8019", subtext: "#d5c4a1", muted: "#928374",
            selection: "#504945", border: "#3c3836",
            colors: ["red": "#fb4934", "orange": "#fe8019", "yellow": "#fabd2f", "green": "#b8bb26",
                     "cyan": "#8ec07c", "blue": "#83a598", "purple": "#d3869b", "pink": "#d3869b"]),
        "gruvbox-light": ThemePalette(
            background: "#fbf1c7", text: "#3c3836", accent: "#af3a03", subtext: "#504945", muted: "#928374",
            selection: "#ebdbb2", border: "#d5c4a1",
            colors: ["red": "#9d0006", "orange": "#af3a03", "yellow": "#b57614", "green": "#79740e",
                     "cyan": "#427b58", "blue": "#076678", "purple": "#8f3f71", "pink": "#8f3f71"]),
        // Tokyo Night by enkia (MIT)
        "tokyo-night": ThemePalette(
            background: "#1a1b26", text: "#c0caf5", accent: "#7aa2f7", subtext: "#a9b1d6", muted: "#565f89",
            selection: "#283457", border: "#292e42",
            colors: ["red": "#f7768e", "orange": "#ff9e64", "yellow": "#e0af68", "green": "#9ece6a",
                     "cyan": "#7dcfff", "blue": "#7aa2f7", "purple": "#9d7cd8", "pink": "#bb9af7"]),
        // Catppuccin, catppuccin.com (MIT)
        "catppuccin-mocha": ThemePalette(
            background: "#1e1e2e", text: "#cdd6f4", accent: "#cba6f7", subtext: "#bac2de", muted: "#7f849c",
            selection: "#45475a", border: "#313244",
            colors: ["red": "#f38ba8", "orange": "#fab387", "yellow": "#f9e2af", "green": "#a6e3a1",
                     "cyan": "#94e2d5", "blue": "#89b4fa", "purple": "#cba6f7", "pink": "#f5c2e7"]),
        "catppuccin-latte": ThemePalette(
            background: "#eff1f5", text: "#4c4f69", accent: "#8839ef", subtext: "#5c5f77", muted: "#8c8fa1",
            selection: "#ccd0da", border: "#ccd0da",
            colors: ["red": "#d20f39", "orange": "#fe640b", "yellow": "#df8e1d", "green": "#40a02b",
                     "cyan": "#179299", "blue": "#1e66f5", "purple": "#8839ef", "pink": "#ea76cb"]),
        // Monokai by Wimer Hazenberg
        "monokai": ThemePalette(
            background: "#272822", text: "#f8f8f2", accent: "#f92672", muted: "#75715e", selection: "#49483e", border: "#3e3d32",
            colors: ["red": "#f92672", "orange": "#fd971f", "yellow": "#e6db74", "green": "#a6e22e",
                     "cyan": "#66d9ef", "blue": "#66d9ef", "purple": "#ae81ff", "pink": "#f92672"]),
    ]

    private static let solarized = ["red": "#dc322f", "orange": "#cb4b16", "yellow": "#b58900", "green": "#859900",
                                    "cyan": "#2aa198", "blue": "#268bd2", "purple": "#6c71c4", "pink": "#d33682"]

    /// Every name `theme` accepts without a file, sorted, `default` first.
    public static var names: [String] { [defaultName] + builtIn.keys.sorted() }

    /// The palette for `name` (nil = the system look). A file in `directory/themes` wins over a built-in of the same name.
    static func resolve(_ name: String, directory: URL?, readFile: (String) -> String?, _ issues: inout [ConfigIssue]) -> (ThemePalette?, file: String?) {
        if name == defaultName { return (nil, nil) } // nothing to read
        let path = directory?.appendingPathComponent(folderName).appendingPathComponent("\(name).toml").path
        if let path, let text = readFile(path) {
            let label = "themes/\(name).toml"
            guard let t = try? TOMLTable(source: text) else {
                issues.append(.warning("\(label) isn't valid TOML, using the default theme")); return (nil, path)
            }
            return (parse(t, label: label, &issues), path)
        }
        if let p = builtIn[name] { return (p, path) }
        issues.append(.warning("appearance.theme: no theme '\(name)' (built in: \(names.joined(separator: ", ")); or add themes/\(name).toml)"))
        return (nil, path)
    }

    /// A theme file: `base = "nord"` to start from a built-in, then any colours. Without a base,
    /// background, text and accent are required.
    static func parse(_ t: TOMLTable, label: String, _ issues: inout [ConfigIssue]) -> ThemePalette? {
        ConfigLoader.warnUnknownKeys(t, known: ThemePalette.keys, in: label, &issues)
        func hex(_ key: String) -> String? {
            guard t.contains(key: key) else { return nil }
            if let s = try? t.string(forKey: key), Appearance.parseHex(s) != nil { return s }
            issues.append(.warning("\(label): \(key) must be a hex colour like \"#7c5cff\""))
            return nil
        }
        var base: ThemePalette?
        if t.contains(key: "base") {
            let name = (try? t.string(forKey: "base")) ?? ""
            base = builtIn[name]
            if base == nil { issues.append(.warning("\(label): base must be one of \(builtIn.keys.sorted().joined(separator: ", "))")) }
        }
        guard let background = hex("background") ?? base?.background,
              let text = hex("text") ?? base?.text,
              let accent = hex("accent") ?? base?.accent else {
            issues.append(.warning("\(label): needs background, text and accent (or base = \"<built-in theme>\"), using the default theme"))
            return nil
        }
        var mode: ThemePalette.Mode?
        if t.contains(key: "mode") {
            if let s = try? t.string(forKey: "mode"), let m = ThemePalette.Mode(rawValue: s) { mode = m }
            else { issues.append(.warning("\(label): mode must be \"dark\" or \"light\"")) }
        }
        // A new background re-decides the mode unless it's given.
        if mode == nil, !t.contains(key: "background") { mode = base?.mode }
        var p = ThemePalette(mode: mode, background: background, text: text, accent: accent,
                             subtext: hex("subtext") ?? base?.subtext, muted: hex("muted") ?? base?.muted,
                             selection: hex("selection") ?? base?.selection, border: hex("border") ?? base?.border,
                             colors: base?.colors ?? [:])
        for name in ThemePalette.colorNames { if let c = hex(name) { p.colors[name] = c } }
        if let base { p.opacity = base.opacity }
        if t.contains(key: "opacity") {
            let value: Double? = (try? t.float(forKey: "opacity")).map { Double($0) } ?? (try? t.integer(forKey: "opacity")).map { Double($0) }
            if let value, (0...1).contains(value) { p.opacity = value }
            else { issues.append(.warning("\(label): opacity must be a number from 0 to 1")) }
        }
        return p
    }
}
