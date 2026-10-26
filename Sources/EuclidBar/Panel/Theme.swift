import AppKit
import EuclidCore

/// Sizes and colours the panel draws with, from `[appearance]` and its `theme`.
/// The default theme is the system look: semantic colours that follow light and dark mode.
@MainActor
struct Theme {
    var accent: NSColor = .controlAccentColor
    var text: NSColor = .labelColor
    var subtext: NSColor = .secondaryLabelColor
    var muted: NSColor = .tertiaryLabelColor
    /// Over the glass or blur; nil = none.
    var background: NSColor?
    var selection: NSColor?
    var border: NSColor = .white.withAlphaComponent(0.12)
    /// Forced light or dark controls; nil = follow the system.
    var appearance: NSAppearance?
    /// Symbol tints by colour name; missing ones are the system colours.
    var colors: [String: NSColor] = [:]
    var compact = false
    var glass = true
    var showSpeed = true

    init() {}

    init(_ a: Appearance) {
        if let p = a.palette {
            let text = Self.color(p.text)
            self.text = text
            subtext = p.subtext.map(Self.color) ?? text.withAlphaComponent(0.72)
            muted = p.muted.map(Self.color) ?? text.withAlphaComponent(0.48)
            accent = Self.color(p.accent)
            background = Self.color(p.background).withAlphaComponent(p.opacity)
            selection = p.selection.map(Self.color)
            border = p.border.map(Self.color) ?? text.withAlphaComponent(0.12)
            appearance = NSAppearance(named: p.mode == .dark ? .darkAqua : .aqua)
            colors = p.colors.mapValues(Self.color)
        }
        if let hex = a.accent { accent = Self.color(hex) }
        compact = a.density == .compact
        glass = a.glass
        showSpeed = a.showSpeed
    }

    /// Already validated by the config parser.
    private static func color(_ hex: String) -> NSColor {
        let c = Appearance.parseHex(hex) ?? (r: 0.5, g: 0.5, b: 0.5)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    var rowHeight: CGFloat { compact ? 32 : 40 }
    var headerHeight: CGFloat { compact ? 22 : 26 }
    var titleSize: CGFloat { compact ? 13 : 14 }
    var iconSize: CGFloat { compact ? 18 : 22 }
    var querySize: CGFloat { compact ? 19 : 22 }

    /// Tint for each kind of row's symbol chip.
    func tint(for row: Row) -> NSColor {
        func named(_ name: String, _ system: NSColor) -> NSColor { colors[name] ?? system }
        return switch row {
        case .clip: named("purple", .systemPurple)
        case .history: named("blue", .systemBlue)
        case .action, .aliasAction, .task: named("orange", .systemOrange)
        case .builtin, .command: colors.isEmpty ? .systemGray : muted
        case .calc: named("green", .systemGreen)
        case .transform: named("cyan", .systemTeal)
        case .snippet: named("pink", .systemPink)
        case .content: named("purple", .systemPurple)
        case .plugin: named("green", .systemMint)
        case .app, .project, .file, .header: subtext
        }
    }

    /// Footer warnings.
    var warning: NSColor { colors["orange"] ?? .systemOrange }
}
