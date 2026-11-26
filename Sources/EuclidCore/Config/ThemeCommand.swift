import Foundation

/// `euclid-bar --theme [name]`: list the themes (yours from `themes/*.toml` too, the one in use
/// marked), or switch to one. Switching edits `[appearance] theme` in config.toml, keeping the rest
/// of the file as it is; Euclid applies a saved config at once, so an open panel changes as you watch.
public enum ThemeCommand {
    public struct Result: Equatable {
        public let output: String
        public let newText: String?   // config.toml to write; nil = leave it
        public let status: Int32
    }

    public static func run(_ args: [String], configText: String, current: String, yourThemes: [String]) -> Result {
        let yours = Set(yourThemes)
        let all = [Themes.defaultName] + Set(Themes.names + yourThemes).subtracting([Themes.defaultName]).sorted()
        guard let name = args.first else {
            let rows = all.map { ($0 == current ? "* " : "  ") + $0 + (yours.contains($0) ? "  (themes/\($0).toml)" : "") }
            return Result(output: (rows + ["", "euclid-bar --theme <name> switches; Euclid applies it at once."]).joined(separator: "\n"),
                          newText: nil, status: 0)
        }
        guard all.contains(name) else {
            let close = all.filter { $0.hasPrefix(name.lowercased()) || $0.contains(name.lowercased()) }
            let hint = close.isEmpty ? "euclid-bar --theme lists them" : "did you mean \(close.joined(separator: ", "))?"
            return Result(output: "error: no theme '\(name)': \(hint)", newText: nil, status: 64)
        }
        guard name != current else { return Result(output: "theme: \(name) (already)", newText: nil, status: 0) }
        guard let text = ConfigEditor.set("theme", to: name, in: "appearance", text: configText) else {
            return Result(output: "error: couldn't change config.toml safely; set [appearance] theme = \"\(name)\" by hand",
                          newText: nil, status: 1)
        }
        return Result(output: "theme: \(name)", newText: text, status: 0)
    }
}
