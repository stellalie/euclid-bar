import Foundation

/// Every colour the panel draws with, worked out from a theme's background, text and accent
/// (plus `[appearance] contrast`), Linear-style: mixed in OKLab so equal steps look equal on any base.
/// Colours a theme names itself win, unless `contrast` is moved off its default.
public struct ThemeColors: Equatable, Sendable {
    public var mode: ThemePalette.Mode
    public var background: String
    public var text: String
    public var accent: String
    /// Detail and hint text.
    public var subtext: String
    /// Section titles, the right-hand column, the faintest text.
    public var muted: String
    /// The selected row's fill (the ring is the accent).
    public var selection: String
    /// The panel's outline.
    public var border: String
    /// The footer strip, a step below the background.
    public var footer: String
    /// The preview card, a step below the footer.
    public var card: String
    /// The plate behind a symbol icon.
    public var chip: String

    public static let defaultContrast = 50

    /// `contrast`: 0–100, 50 = the theme as designed.
    public static func derive(_ p: ThemePalette, contrast: Int = defaultContrast) -> ThemeColors {
        let c = Double(max(0, min(100, contrast))) / 100
        let own = contrast == defaultContrast // keep a theme's hand-picked colours
        let bg = OKLab(hex: p.background), fg = OKLab(hex: p.text), ac = OKLab(hex: p.accent)
        let dark = p.mode == .dark
        func mixed(_ t: Double) -> String { bg.mixed(with: fg, t).hex }
        func step(_ dl: Double) -> String { OKLab(L: bg.L + (dark ? -dl : -dl * 1.2), a: bg.a, b: bg.b).hex }
        return ThemeColors(
            mode: p.mode,
            background: p.background,
            text: p.text,
            accent: p.accent,
            subtext: (own ? p.subtext : nil) ?? mixed(0.62 + 0.25 * c),
            muted: (own ? p.muted : nil) ?? mixed(0.40 + 0.25 * c),
            selection: (own ? p.selection : nil) ?? bg.mixed(with: ac, 0.16 + 0.12 * c).hex,
            border: (own ? p.border : nil) ?? mixed(0.06 + 0.12 * c),
            footer: step(0.025),
            card: step(0.045),
            chip: mixed(0.07 + 0.04 * c)
        )
    }
}

/// A colour in OKLab (Björn Ottosson, 2020): perceptually even, so mixing two colours halfway
/// looks halfway, on any hue.
struct OKLab: Equatable {
    var L: Double, a: Double, b: Double

    init(L: Double, a: Double, b: Double) { (self.L, self.a, self.b) = (L, a, b) }

    /// From an sRGB hex string (already validated; malformed reads as mid grey).
    init(hex: String) {
        let c = Appearance.parseHex(hex) ?? (0.5, 0.5, 0.5)
        self.init(red: c.r, green: c.g, blue: c.b)
    }

    init(red: Double, green: Double, blue: Double) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (linear(red), linear(green), linear(blue))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// sRGB components, clamped to 0–1.
    var rgb: (r: Double, g: Double, b: Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ v: Double) -> Double {
            let x = max(0, min(1, v))
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return (gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    var hex: String {
        let c = rgb
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.r), byte(c.g), byte(c.b))
    }

    /// `t` = 0 is self, 1 is `other`.
    func mixed(with other: OKLab, _ t: Double) -> OKLab {
        OKLab(L: L + (other.L - L) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }
}
