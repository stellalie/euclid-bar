import AppKit
import EuclidCore

/// Sizes and colours the panel draws with, from `[appearance]` and its `theme`.
/// The default theme is the system look: semantic colours that follow light and dark mode.
/// A named theme's colours come from `ThemeColors.derive` (OKLab mixes of its background, text and accent).
@MainActor
struct Theme {
    var accent: NSColor = .controlAccentColor
    var text: NSColor = .labelColor
    var subtext: NSColor = .secondaryLabelColor
    /// tertiaryLabelColor is too faint on a light panel (section names nearly vanish), so light mode is darker.
    var muted: NSColor = Theme.dynamic(dark: .tertiaryLabelColor, light: .black.withAlphaComponent(0.42))
    /// Over the glass or blur; nil = a faint accent tint (`surfaceTint`).
    var background: NSColor?
    var selection: NSColor?
    var border: NSColor = Theme.dynamic(dark: .white.withAlphaComponent(0.12), light: .black.withAlphaComponent(0.10))
    /// The footer strip, a step darker than the panel.
    var footerFill: NSColor = Theme.dynamic(dark: .black.withAlphaComponent(0.16), light: .black.withAlphaComponent(0.035))
    /// The preview card, a step darker still.
    var cardFill: NSColor = Theme.dynamic(dark: .black.withAlphaComponent(0.20), light: .black.withAlphaComponent(0.045))
    /// The plate behind a symbol icon.
    var chipFill: NSColor = Theme.dynamic(dark: .white.withAlphaComponent(0.07), light: .black.withAlphaComponent(0.055))
    /// The 1 pt light along the panel's top edge.
    var glow: NSColor = Theme.dynamic(dark: .white.withAlphaComponent(0.10), light: .white.withAlphaComponent(0.6))
    /// Forced light or dark controls; nil = follow the system.
    var appearance: NSAppearance?
    /// Symbol tints by colour name; missing ones are the system colours.
    var colors: [String: NSColor] = [:]
    var compact = false
    var glass = true
    var showSpeed = true
    var autoPreview = true

    init() {}

    init(_ a: Appearance) {
        if let p = a.palette {
            let c = ThemeColors.derive(p, contrast: a.contrast)
            text = Self.color(c.text)
            subtext = Self.color(c.subtext)
            muted = Self.color(c.muted)
            accent = Self.color(c.accent)
            background = Self.color(c.background).withAlphaComponent(p.opacity)
            selection = Self.color(c.selection)
            border = Self.color(c.border)
            footerFill = Self.color(c.footer).withAlphaComponent(p.opacity)
            cardFill = Self.color(c.card).withAlphaComponent(p.opacity)
            chipFill = Self.color(c.chip)
            glow = c.mode == .dark ? .white.withAlphaComponent(0.08) : .white.withAlphaComponent(0.5)
            appearance = NSAppearance(named: c.mode == .dark ? .darkAqua : .aqua)
            colors = p.colors.mapValues(Self.color)
        } else if a.contrast != ThemeColors.defaultContrast {
            // The system look: contrast moves the dim text levels.
            let c = CGFloat(a.contrast) / 100
            subtext = NSColor.labelColor.withAlphaComponent(0.55 + 0.35 * c)
            muted = NSColor.labelColor.withAlphaComponent(0.30 + 0.35 * c)
        }
        if let hex = a.accent { accent = Self.color(hex) }
        compact = a.density == .compact
        glass = a.glass
        showSpeed = a.showSpeed
        autoPreview = a.autoPreview
    }

    /// Already validated by the config parser.
    private static func color(_ hex: String) -> NSColor {
        let c = Appearance.parseHex(hex) ?? (r: 0.5, g: 0.5, b: 0.5)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// One colour for dark mode, another for light, resolved where it's drawn.
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    /// The system look's faint wash of the accent over the blur, so the panel isn't a flat grey slab.
    var surfaceTint: NSColor? { background == nil ? accent.withAlphaComponent(0.035) : nil }

    /// Where icons, titles, section names and the typed text all start, from the panel's left edge.
    static let gutter: CGFloat = 22

    var rowHeight: CGFloat { compact ? 32 : 42 }
    var headerHeight: CGFloat { compact ? 24 : 30 }
    var titleSize: CGFloat { compact ? 13 : 14 }
    var iconSize: CGFloat { compact ? 18 : 24 }
    var querySize: CGFloat { compact ? 19 : 23 }

    /// Tint for each kind of row's symbol. Colour only where it says something
    /// (actions and tasks run things, answers are computed); everything else is a quiet glyph.
    func tint(for row: Row) -> NSColor {
        func named(_ name: String, _ system: NSColor) -> NSColor { colors[name] ?? system }
        return switch row {
        case .action, .aliasAction, .task: named("orange", .systemOrange)
        case .calc: named("green", .systemGreen)
        case .transform: named("cyan", .systemTeal)
        case .clip, .history, .builtin, .command, .snippet, .content, .plugin, .app, .project, .file, .header: subtext
        }
    }

    /// Footer warnings.
    var warning: NSColor { colors["orange"] ?? .systemOrange }
}

extension NSView {
    /// Set layer colours as this view looks now (dynamic colours resolve against its appearance).
    func resolving(_ body: () -> Void) {
        effectiveAppearance.performAsCurrentDrawingAppearance(body)
    }
}
