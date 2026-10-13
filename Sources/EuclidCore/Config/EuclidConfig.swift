import Foundation
import TOMLDecoder

/// Everything `config.toml` can set. Every field has a default, so an empty file is valid.
public struct EuclidConfig: Equatable, Sendable {
    public var hotkey: HotkeySpec?          // nil = keep whatever is set in the app
    public var clipboardLimit = 5_000
    public var ignoredApps: Set<String> = []
    public var shellPath = "/bin/zsh"
    /// Enabled actions, in file order. Position = number shortcut (⌘1 = first).
    public var actions: [Action] = []

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

        warnUnknownKeys(root, known: ["hotkey", "clipboard", "shell", "action"], in: "top level", &issues)

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

        if root.contains(key: "action") {
            if let list = try? root.array(forKey: "action") {
                for i in 0..<list.count {
                    let label = "action #\(i + 1)"
                    guard let t = try? list.table(atIndex: i) else {
                        issues.append(.warning("\(label): use [[action]] blocks")); continue
                    }
                    if let action = parseAction(t, label: label, &issues) { config.actions.append(action) }
                }
            } else {
                issues.append(.warning("actions must be [[action]] blocks"))
            }
        }

        return LoadedConfig(config: config, issues: issues)
    }

    private static func parseAction(_ t: TOMLTable, label: String, _ issues: inout [ConfigIssue]) -> Action? {
        warnUnknownKeys(t, known: ["name", "run", "output"], in: label, &issues)
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

    private static func warnUnknownKeys(_ t: TOMLTable, known: Set<String>, in place: String, _ issues: inout [ConfigIssue]) {
        for key in t.keys.sorted() where !known.contains(key) {
            issues.append(.warning("\(place): unknown key '\(key)'"))
        }
    }

    /// Install helper scripts (e.g. `ghostty-run`) into `<config>/bin` if missing.
    /// Existing files are never touched: they're the user's to edit.
    public static func installDefaultScripts(in binDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        for script in DefaultScripts.all {
            let url = binDirectory.appendingPathComponent(script.name)
            guard !fm.fileExists(atPath: url.path) else { continue }
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
