import Foundation

/// A parsed, validated hotkey like `opt+space` or `cmd+shift+k`.
public struct HotkeySpec: Hashable, Sendable {
    public enum Modifier: String, Sendable, CaseIterable { case command, option, control, shift }

    public let modifiers: Set<Modifier>
    /// Normalized key name: "a"–"z", "0"–"9", "space", "return", "tab", "f1"–"f12".
    public let key: String

    static let modifierAliases: [String: Modifier] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
        "shift": .shift, "⇧": .shift,
    ]

    static let namedKeys: Set<String> = Set(["space", "return", "tab"])
        .union((1...12).map { "f\($0)" })

    public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// How macOS menus write it: "⌃⌥T", "⇧⌘Space", "F5".
    public var symbols: String {
        let order: [(Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let mods = order.filter { modifiers.contains($0.0) }.map(\.1).joined()
        let name = switch key {
        case "space": "Space"
        case "return": "↩"
        case "tab": "⇥"
        default: key.uppercased()
        }
        return mods + name
    }

    public static func parse(_ text: String) -> Result<HotkeySpec, ParseError> {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let rawKey = parts.last, !rawKey.isEmpty else { return .failure(ParseError(message: "empty hotkey")) }

        var mods = Set<Modifier>()
        for p in parts.dropLast() {
            guard let m = modifierAliases[p] else { return .failure(ParseError(message: "unknown modifier '\(p)' (use cmd, opt, ctrl, shift)")) }
            mods.insert(m)
        }
        let key = rawKey == "enter" ? "return" : rawKey
        let isSingleChar = key.count == 1 && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        guard isSingleChar || namedKeys.contains(key) else {
            return .failure(ParseError(message: "unknown key '\(rawKey)' (use a–z, 0–9, space, return, tab, f1–f12)"))
        }
        let isFunctionKey = key.count > 1 && key.hasPrefix("f")
        if mods.isEmpty && !isFunctionKey {
            return .failure(ParseError(message: "'\(text)' needs a modifier, or it would block normal typing"))
        }
        return .success(HotkeySpec(modifiers: mods, key: key))
    }
}

/// A global hotkey that runs one thing without opening the panel: `[hotkeys]`, or `hotkey`
/// on an `[[action]]` or `[[snippet]]`.
public struct CommandHotkey: Equatable, Sendable {
    public enum Kind: String, Sendable { case action, snippet }

    public let hotkey: HotkeySpec
    /// An app, project, action or snippet, by name (as in `[aliases]`).
    public let target: String
    /// Set when the hotkey sits in an action or snippet block: that one, even if an app shares its name.
    public let kind: Kind?

    public init(hotkey: HotkeySpec, target: String, kind: Kind? = nil) {
        self.hotkey = hotkey
        self.target = target
        self.kind = kind
    }
}
