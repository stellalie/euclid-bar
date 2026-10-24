import AppKit
import EuclidCore

/// Sizes and colours the panel draws with, from `[appearance]`.
@MainActor
struct Theme {
    var accent: NSColor = .controlAccentColor
    var compact = false
    var glass = true
    var showSpeed = true

    init() {}

    init(_ a: Appearance) {
        if let hex = a.accent, let c = Appearance.parseHex(hex) {
            accent = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
        compact = a.density == .compact
        glass = a.glass
        showSpeed = a.showSpeed
    }

    var rowHeight: CGFloat { compact ? 32 : 40 }
    var headerHeight: CGFloat { compact ? 22 : 26 }
    var titleSize: CGFloat { compact ? 13 : 14 }
    var iconSize: CGFloat { compact ? 18 : 22 }
    var querySize: CGFloat { compact ? 19 : 22 }

    /// Tint for each kind of row's symbol chip.
    static func tint(for row: Row) -> NSColor {
        switch row {
        case .clip: .systemPurple
        case .history: .systemBlue
        case .action, .aliasAction: .systemOrange
        case .builtin: .systemGray
        case .calc: .systemGreen
        case .transform: .systemTeal
        case .snippet: .systemPink
        case .content(let c): c.kind == .note ? .systemPurple : .systemIndigo
        case .bitbucket: .systemBlue
        case .app, .project, .file, .header: .secondaryLabelColor
        }
    }
}
