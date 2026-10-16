import CryptoKit
import Foundation
import TOMLDecoder

/// Everything `config.toml` can set. Every field has a default, so an empty file is valid.
public struct EuclidConfig: Equatable, Sendable {
    public var hotkey: HotkeySpec?          // nil = keep whatever is set in the app
    public var clipboardLimit = 5_000
    public var ignoredApps: Set<String> = []
    public var shellPath = "/bin/zsh"
    /// Extra environment for every action (`[env]`). For variables your shell only
    /// sets in interactive mode (~/.zshrc), which background actions don't load.
    public var environment: [String: String] = [:]
    /// Browser history search (`[history]`).
    public var historyEnabled = true
    public var historyBrowsers: Set<String>? = nil   // nil = every browser found
    public var historyLimit = 5_000
    /// Enabled actions, in file order. Position = number shortcut (⌘1 = first).
    public var actions: [Action] = []
    /// Installed apps in search (`[apps]`).
    public var appsEnabled = true
    public var appFolders: [String] = AppIndex.defaultFolders
    /// Git repos in search (`[projects]`). Roots that don't exist are skipped.
    public var projectRoots: [String] = ["~/code", "~/src", "~/dev", "~/Developer", "~/projects", "~/work"]
    public var projectDepth = 3
    /// Shell command that opens a project; its path is `$1`.
    public var projectOpen = #"open "$1""#
    /// Spotlight file search (`[files]`).
    public var filesEnabled = true
    public var filesLimit = 8
    /// Shown when the search box is empty (`[search] favorites`), by title.
    public var favorites: [String] = []
    /// `[aliases]` plus every action's `alias`.
    public var aliases = Aliases()

    public init() {}
}

public struct ConfigIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public let severity: Severity
    public let message: String
    public var description: String { "\(severity): \(message)" }

    static func warning(_ m: String) -> ConfigIssue { .init(severity: .warning, message: m) }
    static func error(_ m: String) -> ConfigIssue { .init(severity: .error, message: m) }
}

public struct LoadedConfig: Equatable, Sendable {
    public let config: EuclidConfig
    /// Non-fatal problems. The config is still usable; offending parts are skipped.
    public let issues: [ConfigIssue]

    public init(config: EuclidConfig, issues: [ConfigIssue]) {
        self.config = config
        self.issues = issues
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case syntax(String)        // the file isn't valid TOML
    case unreadable(String)
    public var description: String {
        switch self {
        case .syntax(let m): "config.toml: \(m)"
        case .unreadable(let m): "config.toml: \(m)"
        }
    }
}

public enum ConfigLoader {
    /// Parse and validate. Throws only when the file isn't valid TOML;
    /// everything else becomes an issue so one typo never disables the whole config.
    public static func parse(_ text: String, fileExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) throws(ConfigError) -> LoadedConfig {
        let root: TOMLTable
        do { root = try TOMLTable(source: text) } catch { throw .syntax(String(describing: error)) }

        var config = EuclidConfig()
        var issues: [ConfigIssue] = []

        warnUnknownKeys(root, known: ["hotkey", "clipboard", "shell", "env", "history", "apps", "projects", "files", "search", "aliases", "action"], in: "top level", &issues)

        if root.contains(key: "hotkey") {
            if let s = try? root.string(forKey: "hotkey") {
                switch HotkeySpec.parse(s) {
                case .success(let spec): config.hotkey = spec
                case .failure(let e): issues.append(.warning("hotkey: \(e.message)"))
                }
            } else {
                issues.append(.warning("hotkey must be a string like \"opt+space\""))
            }
        }

        if root.contains(key: "clipboard") {
            if let t = try? root.table(forKey: "clipboard") {
                warnUnknownKeys(t, known: ["limit", "ignore_apps"], in: "[clipboard]", &issues)
                if t.contains(key: "limit") {
                    if let n = try? t.integer(forKey: "limit"), (1...100_000).contains(n) {
                        config.clipboardLimit = Int(n)
                    } else {
                        issues.append(.warning("clipboard.limit must be a number from 1 to 100000"))
                    }
                }
                if t.contains(key: "ignore_apps") {
                    if let a = try? t.array(forKey: "ignore_apps") {
                        config.ignoredApps = Set((0..<a.count).compactMap { try? a.string(atIndex: $0) })
                    } else {
                        issues.append(.warning("clipboard.ignore_apps must be a list of bundle IDs"))
                    }
                }
            } else {
                issues.append(.warning("clipboard must be a table: [clipboard]"))
            }
        }

        if root.contains(key: "shell") {
            if let t = try? root.table(forKey: "shell") {
                warnUnknownKeys(t, known: ["path"], in: "[shell]", &issues)
                if t.contains(key: "path") {
                    if let p = try? t.string(forKey: "path"), fileExists(p) {
                        config.shellPath = p
                    } else {
                        issues.append(.warning("shell.path is not an executable file; using /bin/zsh"))
                    }
                }
            } else {
                issues.append(.warning("shell must be a table: [shell]"))
            }
        }

        if root.contains(key: "env") {
            if let t = try? root.table(forKey: "env") {
                for key in t.keys.sorted() {
                    guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                        issues.append(.warning("env: '\(key)' isn't a valid variable name")); continue
                    }
                    guard let value = try? t.string(forKey: key) else {
                        issues.append(.warning("env.\(key) must be a string (use quotes)")); continue
                    }
                    config.environment[key] = value
                }
            } else {
                issues.append(.warning("env must be a table: [env]"))
            }
        }

        if root.contains(key: "history") {
            if let t = try? root.table(forKey: "history") {
                warnUnknownKeys(t, known: ["enabled", "browsers", "limit"], in: "[history]", &issues)
                if t.contains(key: "enabled") {
                    if let b = try? t.bool(forKey: "enabled") { config.historyEnabled = b }
                    else { issues.append(.warning("history.enabled must be true or false")) }
                }
                if t.contains(key: "limit") {
                    if let n = try? t.integer(forKey: "limit"), (1...100_000).contains(n) { config.historyLimit = Int(n) }
                    else { issues.append(.warning("history.limit must be a number from 1 to 100000")) }
                }
                if t.contains(key: "browsers") {
                    if let a = try? t.array(forKey: "browsers") {
                        var keys = Set<String>()
                        for i in 0..<a.count {
                            guard let k = try? a.string(atIndex: i) else { continue }
                            if BrowserHistory.knownKeys.contains(k.lowercased()) { keys.insert(k.lowercased()) }
                            else {
                                let valid = BrowserHistory.knownKeys.sorted().joined(separator: ", ")
                                issues.append(.warning("history.browsers: unknown browser '\(k)' (use \(valid))"))
                            }
                        }
                        config.historyBrowsers = keys
                    } else {
                        issues.append(.warning("history.browsers must be a list, e.g. [\"dia\", \"safari\"]"))
                    }
                }
            } else {
                issues.append(.warning("history must be a table: [history]"))
            }
        }

        if let t = table(root, "apps", &issues) {
            warnUnknownKeys(t, known: ["enabled", "folders"], in: "[apps]", &issues)
            if let b = bool(t, "enabled", in: "apps", &issues) { config.appsEnabled = b }
            if let a = strings(t, "folders", in: "apps", &issues) { config.appFolders = AppIndex.defaultFolders + a }
        }

        if let t = table(root, "projects", &issues) {
            warnUnknownKeys(t, known: ["roots", "depth", "open"], in: "[projects]", &issues)
            if let a = strings(t, "roots", in: "projects", &issues) { config.projectRoots = a }
            if t.contains(key: "depth") {
                if let n = try? t.integer(forKey: "depth"), (1...6).contains(n) { config.projectDepth = Int(n) }
                else { issues.append(.warning("projects.depth must be a number from 1 to 6")) }
            }
            if t.contains(key: "open") {
                if let s = try? t.string(forKey: "open"), !s.trimmingCharacters(in: .whitespaces).isEmpty { config.projectOpen = s }
                else { issues.append(.warning("projects.open must be a command, e.g. 'code \"$1\"'")) }
            }
        }

        if let t = table(root, "files", &issues) {
            warnUnknownKeys(t, known: ["enabled", "limit"], in: "[files]", &issues)
            if let b = bool(t, "enabled", in: "files", &issues) { config.filesEnabled = b }
            if t.contains(key: "limit") {
                if let n = try? t.integer(forKey: "limit"), (1...30).contains(n) { config.filesLimit = Int(n) }
                else { issues.append(.warning("files.limit must be a number from 1 to 30")) }
            }
        }

        if let t = table(root, "search", &issues) {
            warnUnknownKeys(t, known: ["favorites"], in: "[search]", &issues)
            if let a = strings(t, "favorites", in: "search", &issues) { config.favorites = a }
        }

        if let t = table(root, "aliases", &issues) {
            for key in t.keys.sorted() {
                guard let target = try? t.string(forKey: key), !target.isEmpty else {
                    issues.append(.warning("aliases.\(key) must be the name of an app, project or action")); continue
                }
                guard !key.contains(" ") else { issues.append(.warning("aliases: '\(key)' can't contain spaces")); continue }
                config.aliases.add(key, target: target)
            }
        }

        if root.contains(key: "action") {
            if let list = try? root.array(forKey: "action") {
                for i in 0..<list.count {
                    let label = "action #\(i + 1)"
                    guard let t = try? list.table(atIndex: i) else {
                        issues.append(.warning("\(label): use [[action]] blocks")); continue
                    }
                    if let action = parseAction(t, label: label, &issues) {
                        config.actions.append(action)
                        if let alias = try? t.string(forKey: "alias") {
                            if alias.contains(" ") || alias.isEmpty { issues.append(.warning("\(label): alias can't be empty or contain spaces")) }
                            else { config.aliases.add(alias, target: action.name) }
                        }
                    }
                }
            } else {
                issues.append(.warning("actions must be [[action]] blocks"))
            }
        }

        return LoadedConfig(config: config, issues: issues)
    }

    private static func parseAction(_ t: TOMLTable, label: String, _ issues: inout [ConfigIssue]) -> Action? {
        warnUnknownKeys(t, known: ["name", "run", "output", "alias"], in: label, &issues)
        guard let name = try? t.string(forKey: "name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            issues.append(.warning("\(label): missing name, skipped")); return nil
        }
        let label = "\(label) '\(name)'"
        guard let run = try? t.string(forKey: "run"), !run.trimmingCharacters(in: .whitespaces).isEmpty else {
            issues.append(.warning("\(label): missing run command, skipped")); return nil
        }
        var output = Action.Output.background
        if t.contains(key: "output") {
            let raw = (try? t.string(forKey: "output")) ?? ""
            guard let o = Action.Output(rawValue: raw) else {
                if raw.hasPrefix("ghostty-") {
                    let place = raw.dropFirst("ghostty-".count)
                    issues.append(.warning("\(label): output '\(raw)' was replaced by a script: remove output and use run = 'ghostty-run \(place) <command>', skipped"))
                    return nil
                }
                let valid = Action.Output.allCases.map(\.rawValue).joined(separator: ", ")
                issues.append(.warning("\(label): unknown output '\(raw)' (use \(valid)), skipped")); return nil
            }
            guard o.isAvailable else {
                issues.append(.warning("\(label): output '\(raw)' isn't supported yet, skipped")); return nil
            }
            output = o
        }
        return Action(name: name, run: run, output: output)
    }

    /// `[name]` if present and a table; a warning if present but not a table.
    private static func table(_ root: TOMLTable, _ name: String, _ issues: inout [ConfigIssue]) -> TOMLTable? {
        guard root.contains(key: name) else { return nil }
        if let t = try? root.table(forKey: name) { return t }
        issues.append(.warning("\(name) must be a table: [\(name)]"))
        return nil
    }

    private static func bool(_ t: TOMLTable, _ key: String, in place: String, _ issues: inout [ConfigIssue]) -> Bool? {
        guard t.contains(key: key) else { return nil }
        if let b = try? t.bool(forKey: key) { return b }
        issues.append(.warning("\(place).\(key) must be true or false"))
        return nil
    }

    private static func strings(_ t: TOMLTable, _ key: String, in place: String, _ issues: inout [ConfigIssue]) -> [String]? {
        guard t.contains(key: key) else { return nil }
        guard let a = try? t.array(forKey: key) else {
            issues.append(.warning("\(place).\(key) must be a list of strings")); return nil
        }
        return (0..<a.count).compactMap { try? a.string(atIndex: $0) }
    }

    private static func warnUnknownKeys(_ t: TOMLTable, known: Set<String>, in place: String, _ issues: inout [ConfigIssue]) {
        for key in t.keys.sorted() where !known.contains(key) {
            issues.append(.warning("\(place): unknown key '\(key)'"))
        }
    }

    /// Install helper scripts (e.g. `ghostty-run`) into `<config>/bin` if missing,
    /// or upgrade them if they're an unmodified older version. Edited files are never touched.
    public static func installDefaultScripts(in binDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        for script in DefaultScripts.all {
            let url = binDirectory.appendingPathComponent(script.name)
            if let existing = fm.contents(atPath: url.path) {
                let hash = SHA256.hash(data: existing).map { String(format: "%02x", $0) }.joined()
                let isUnmodifiedOldVersion = DefaultScripts.previousVersions[script.name]?.contains(hash) ?? false
                guard isUnmodifiedOldVersion else { continue } // current, or edited by the user
            }
            try script.text.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// Read the config file, creating a commented default on first run.
    public static func loadOrCreate(at url: URL) throws(ConfigError) -> LoadedConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try DefaultConfig.text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw .unreadable("can't create \(url.path): \(error.localizedDescription)")
            }
        }
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw .unreadable("can't read \(url.path): \(error.localizedDescription)")
        }
        return try parse(text)
    }
}
