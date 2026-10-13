import Foundation

/// A parsed, validated hotkey like `opt+space` or `cmd+shift+k`.
public struct HotkeySpec: Equatable, Sendable {
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
