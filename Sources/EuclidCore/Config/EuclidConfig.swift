import CryptoKit
import Foundation
import TOMLDecoder

/// Everything `config.toml` can set. Every field has a default, so an empty file is valid.
public struct EuclidConfig: Equatable, Sendable {
    public var hotkey: HotkeySpec?          // nil = keep whatever is set in the app
    public var clipboardLimit = 5_000
    public var ignoredApps: Set<String> = []
    public var shellPath = "/bin/zsh"
    /// What Edit Config… opens config.toml with (`editor`): an app name, or a command.
    /// Nil = the macOS default text editor.
    public var editor: String?
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
    /// Shell command that runs a project task (⌘K on a project); `$1` is `cd '<repo>' && make test`.
    /// `eval` in the new tab leaves you in the repo afterwards.
    public var projectTask = #"ghostty-run tab eval "$1""#
    /// Spotlight file search (`[files]`).
    public var filesEnabled = true
    public var filesLimit = 8
    /// Shown when the search box is empty (`[search] favorites`), by title.
    public var favorites: [String] = []
    /// `[aliases]` plus every action's `alias`.
    public var aliases = Aliases()
    /// Look and feel (`[appearance]`).
    public var appearance = Appearance()
    /// `[[snippet]]` blocks, in file order.
    public var snippets: [Snippet] = []
    /// Snippet keywords expand as you type them in any app (`[expansion] enabled`).
    /// Off by default: it needs Accessibility access to see keystrokes.
    public var expansionEnabled = false
    /// Hotkeys that run an app, project, action or snippet directly. Validated: no duplicates.
    public var commandHotkeys: [CommandHotkey] = []
    /// Full-text index of visited pages (`[pages]`). Off by default: it downloads pages.
    public var pagesEnabled = false
    public var pagesLimit = 500
    public var pagesExcludedHosts: [String] = []
    /// Obsidian vault for note search (`[obsidian] vault`). Nil = off.
    public var obsidianVault: String?
    /// Bitbucket integration (`[bitbucket]`). Nil = off.
    public var bitbucket: BitbucketSettings?
    /// Jira integration (`[jira]`). Nil = off.
    public var jira: JiraSettings?
    /// What `euclid-bar --mcp` shares with coding agents (`[agents] share`).
    public var agentShare = Set(AgentTools.Source.allCases)
    /// Sparkle auto-update (`[updates]`).
    public var updates = UpdateSettings()
    /// Installed plugins, from `<config>/plugins` and `[plugins] paths`, minus `disabled`.
    public var plugins: [Plugin] = []
    /// `[plugins] paths`: more folders of plugins (a team repo's), after `<config>/plugins`.
    public var pluginPaths: [String] = []
    public var pluginsDisabled: Set<String> = []
    /// The coding agent `mod:` in the bar hands requests to (`[mods] agent`), as you'd type it.
    /// It runs in a terminal via `[projects] task`, in the plugins folder, with the request as its argument.
    public var modAgent = "claude"
    /// Where plugins were looked for: `<config>/plugins`, then `[plugins] paths`.
    public var pluginDirectories: [String] = []
    /// `[plugin.<id>]`: your values for a plugin's settings.
    public var pluginSettings: [String: [String: String]] = [:]

    public init() {}
}

/// `[updates]`. Only signed builds update; local builds ignore it.
public struct UpdateSettings: Equatable, Sendable {
    /// Look for a new version once a day.
    public var check = true
    /// Download new versions in the background and install them on quit. Needs `check`.
    public var autoInstall = true
    /// Which builds to get: tagged releases, or a build of every change merged to main.
    public var channel = Channel.stable

    public enum Channel: String, Sendable, CaseIterable { case stable, dev }

    public init() {}
}

/// `[appearance]`.
public struct Appearance: Equatable, Sendable {
    public enum Density: String, Sendable, CaseIterable { case comfortable, compact }
    /// A built-in theme or `<config>/themes/<name>.toml`; "default" is the system look.
    public var theme = Themes.defaultName
    /// The theme's colours, nil for the system look. `accent` below still wins over the theme's.
    public var palette: ThemePalette?
    /// sRGB hex like "#7c5cff"; nil = the system accent colour.
    public var accent: String?
    public var density = Density.comfortable
    /// Liquid Glass background on macOS 26+ (falls back to the blurred material).
    public var glass = true
    /// "12,431 items · 0.6 ms" in the footer.
    public var showSpeed = true

    public init() {}

    /// "#abc" or "#aabbcc" → 0–1 components, or nil if malformed.
    public static func parseHex(_ s: String) -> (r: Double, g: Double, b: Double)? {
        var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let v = Int(hex, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// What a background-fetched integration needs: where its token comes from and how often to refresh.
public protocol RemoteSourceSettings: Equatable, Sendable {
    var tokenCommand: String { get }
    var refreshMinutes: Int { get }
}

/// `[bitbucket]`: Cloud (api.bitbucket.org) or Data Center (your server's URL).
public struct BitbucketSettings: RemoteSourceSettings {
    public var baseURL = "https://api.bitbucket.org/2.0"
    /// Cloud: your Atlassian account email (API tokens use Basic auth). Data Center: leave empty (Bearer token).
    public var email = ""
    /// Prints the token. Keeps secrets out of config.toml (Keychain, 1Password CLI…).
    public var tokenCommand = "security find-generic-password -s euclid-bitbucket -w"
    /// Cloud: "workspace/repo" slugs checked for PRs waiting on your review. Empty = your most recently updated repos.
    public var repos: [String] = []
    public var refreshMinutes = 5

    public var isCloud: Bool { baseURL.contains("api.bitbucket.org") }
    public init() {}
}

/// `[jira]`: Cloud (`https://<site>.atlassian.net`) or Data Center (your server's URL).
public struct JiraSettings: RemoteSourceSettings {
    /// Required: there's no default Jira.
    public var baseURL = ""
    /// Cloud: your Atlassian account email (API tokens use Basic auth). Data Center: leave empty (Bearer token).
    public var email = ""
    public var tokenCommand = "security find-generic-password -s euclid-jira -w"
    /// Which issues to keep in search.
    public var jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    /// Also the issues you viewed lately.
    public var recent = true
    public var refreshMinutes = 5

    public var isCloud: Bool { URL(string: baseURL)?.host?.hasSuffix(".atlassian.net") ?? false }
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
    /// Absolute paths of the files `include` pulled in, in order (watched for changes too).
    public let includedFiles: [String]
    /// Plugin folders and the files in them, watched so a plugin reloads on save.
    public let pluginFiles: [String]
    /// The themes folder and the chosen theme's file (which may not exist yet), watched the same way.
    public let themeFiles: [String]

    public init(config: EuclidConfig, issues: [ConfigIssue], includedFiles: [String] = [], pluginFiles: [String] = [], themeFiles: [String] = []) {
        self.config = config
        self.issues = issues
        self.includedFiles = includedFiles
        self.pluginFiles = pluginFiles
        self.themeFiles = themeFiles
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
    ///
    /// `include = ["~/work/team/euclid.toml"]` pulls in shared files (a team's actions,
    /// snippets and integrations) underneath this one: settings here win, and this file's
    /// actions and snippets come first, so ⌘1 stays yours. Relative paths are from `directory`.
    public static func parse(
        _ text: String,
        directory: URL? = nil,
        fileExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) throws(ConfigError) -> LoadedConfig {
        let root: TOMLTable
        do { root = try TOMLTable(source: text) } catch { throw .syntax(String(describing: error)) }

        var config = EuclidConfig()
        var issues: [ConfigIssue] = []
        var included: [String] = []

        if let paths = includes(root, &issues) {
            for path in paths {
                let resolved = resolve(path, from: directory)
                let name = (path as NSString).lastPathComponent
                guard let includedText = readFile(resolved) else {
                    issues.append(.warning("include: can't read '\(path)', skipped")); continue
                }
                guard let table = try? TOMLTable(source: includedText) else {
                    issues.append(.warning("include: '\(path)' isn't valid TOML, skipped")); continue
                }
                included.append(resolved)
                var own: [ConfigIssue] = []
                apply(table, to: &config, isInclude: true, fileExists: fileExists, &own)
                issues += own.map { .init(severity: $0.severity, message: "\(name): \($0.message)") }
            }
        }

        // Shared actions and snippets go after this file's own; a same-named one here replaces it.
        let sharedActions = config.actions, sharedSnippets = config.snippets, sharedHotkeys = config.commandHotkeys
        config.actions = []
        config.snippets = []
        config.commandHotkeys = []
        apply(root, to: &config, isInclude: false, fileExists: fileExists, &issues)
        let ownActions = Set(config.actions.map(\.name)), ownSnippets = Set(config.snippets.map(\.name))
        config.actions += sharedActions.filter { !ownActions.contains($0.name) }
        config.snippets += sharedSnippets.filter { !ownSnippets.contains($0.name) }
        // Your hotkey for something replaces the team's for it.
        let own = config.commandHotkeys
        let merged = own + sharedHotkeys.filter { s in !own.contains { $0.target == s.target && $0.kind == s.kind } }
        config.commandHotkeys = []
        for h in merged {
            if h.hotkey == config.hotkey {
                issues.append(.warning("hotkey \(h.hotkey.symbols) for '\(h.target)' is the panel's hotkey, skipped")); continue
            }
            if let taken = config.commandHotkeys.first(where: { $0.hotkey == h.hotkey }) {
                issues.append(.warning("hotkey \(h.hotkey.symbols) is already '\(taken.target)', so '\(h.target)' skipped")); continue
            }
            config.commandHotkeys.append(h)
        }
        if config.expansionEnabled {
            issues += TextExpander.shadowedKeywords(in: config.snippets).map {
                .warning("snippet keyword '\($0.long)' never expands: '\($0.short)' fires first")
            }
        }

        // Checked once everything is merged: a team file can set base_url and repos, you the email.
        if let b = config.bitbucket, b.isCloud, b.email.isEmpty {
            issues.append(.warning("bitbucket.email is required for Bitbucket Cloud (your Atlassian account email)"))
            config.bitbucket = nil
        }
        if let j = config.jira, j.baseURL.isEmpty {
            issues.append(.warning("jira.base_url is required, e.g. \"https://your-site.atlassian.net\""))
            config.jira = nil
        } else if let j = config.jira, j.isCloud, j.email.isEmpty {
            issues.append(.warning("jira.email is required for Jira Cloud (your Atlassian account email)"))
            config.jira = nil
        }

        // Plugins: <config>/plugins first, then [plugins] paths. Their actions come after everyone else's.
        var pluginFiles: [String] = []
        if let directory {
            let dirs = [EuclidPaths.pluginsFolderName].map { directory.appendingPathComponent($0).path } + config.pluginPaths.map { resolve($0, from: directory) }
            let (plugins, watched) = PluginLoader.load(directories: dirs, disabled: config.pluginsDisabled,
                                                       overrides: config.pluginSettings, &issues)
            config.plugins = plugins
            config.pluginDirectories = dirs
            pluginFiles = dirs + watched
            var names = Set(config.actions.map(\.name))
            for plugin in plugins {
                for a in plugin.actions where names.insert(a.name).inserted {
                    config.actions.append(Action(name: a.name, run: a.run, output: a.output,
                                                 directory: plugin.directory, environment: plugin.environment))
                }
            }
        }

        let (palette, themeFile) = Themes.resolve(config.appearance.theme, directory: directory, readFile: readFile, &issues)
        config.appearance.palette = palette
        let themeFiles = themeFile.map { [($0 as NSString).deletingLastPathComponent, $0] } ?? []

        return LoadedConfig(config: config, issues: issues, includedFiles: included, pluginFiles: pluginFiles, themeFiles: themeFiles)
    }

    /// `include`: a path or a list of paths.
    private static func includes(_ root: TOMLTable, _ issues: inout [ConfigIssue]) -> [String]? {
        guard root.contains(key: "include") else { return nil }
        if let s = try? root.string(forKey: "include") { return [s] }
        if let a = try? root.array(forKey: "include") { return (0..<a.count).compactMap { try? a.string(atIndex: $0) } }
        issues.append(.warning("include must be a path or a list of paths, e.g. [\"~/work/team/euclid.toml\"]"))
        return nil
    }

    /// `~/x` → home, `x` → next to config.toml.
    static func resolve(_ path: String, from directory: URL?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/"), let directory else { return expanded }
        return directory.appendingPathComponent(expanded).standardizedFileURL.path
    }

    /// Read one file's settings into `config`, on top of what's already there.
    private static func apply(_ root: TOMLTable, to config: inout EuclidConfig, isInclude: Bool,
                              fileExists: (String) -> Bool, _ issues: inout [ConfigIssue]) {
        warnUnknownKeys(root, known: ["include", "hotkey", "editor", "clipboard", "shell", "env", "history", "apps", "projects", "files", "search", "aliases", "action", "appearance", "snippet", "pages", "obsidian", "bitbucket", "jira", "agents", "updates", "hotkeys", "expansion", "plugins", "plugin", "mods"], in: "top level", &issues)
        if isInclude, root.contains(key: "include") {
            issues.append(.warning("include only works in config.toml, not in an included file"))
        }

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

        if root.contains(key: "editor") {
            if let s = try? root.string(forKey: "editor") {
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                config.editor = trimmed.isEmpty ? nil : trimmed
            } else {
                issues.append(.warning("editor must be a string: an app like \"Sublime Text\" or a command like \"code\""))
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
            warnUnknownKeys(t, known: ["roots", "depth", "open", "task"], in: "[projects]", &issues)
            if let a = strings(t, "roots", in: "projects", &issues) { config.projectRoots = a }
            if t.contains(key: "depth") {
                if let n = try? t.integer(forKey: "depth"), (1...6).contains(n) { config.projectDepth = Int(n) }
                else { issues.append(.warning("projects.depth must be a number from 1 to 6")) }
            }
            if t.contains(key: "open") {
                if let s = try? t.string(forKey: "open"), !s.trimmingCharacters(in: .whitespaces).isEmpty { config.projectOpen = s }
                else { issues.append(.warning("projects.open must be a command, e.g. 'code \"$1\"'")) }
            }
            if t.contains(key: "task") {
                if let s = try? t.string(forKey: "task"), !s.trimmingCharacters(in: .whitespaces).isEmpty { config.projectTask = s }
                else { issues.append(.warning("projects.task must be a command, e.g. 'herdr-run tab eval \"$1\"'")) }
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
                        if let h = commandHotkey(t, target: action.name, kind: .action, in: "\(label) '\(action.name)'", &issues) {
                            config.commandHotkeys.append(h)
                        }
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

        if let t = table(root, "appearance", &issues) {
            warnUnknownKeys(t, known: ["theme", "accent", "density", "glass", "show_speed"], in: "[appearance]", &issues)
            if t.contains(key: "theme") {
                if let s = try? t.string(forKey: "theme"), !s.isEmpty, !s.contains("/") { config.appearance.theme = s }
                else { issues.append(.warning("appearance.theme must be a theme name like \"nord\"")) }
            }
            if t.contains(key: "accent") {
                if let s = try? t.string(forKey: "accent"), Appearance.parseHex(s) != nil { config.appearance.accent = s }
                else { issues.append(.warning("appearance.accent must be a hex colour like \"#7c5cff\"")) }
            }
            if t.contains(key: "density") {
                if let s = try? t.string(forKey: "density"), let d = Appearance.Density(rawValue: s) { config.appearance.density = d }
                else { issues.append(.warning("appearance.density must be \"comfortable\" or \"compact\"")) }
            }
            if let b = bool(t, "glass", in: "appearance", &issues) { config.appearance.glass = b }
            if let b = bool(t, "show_speed", in: "appearance", &issues) { config.appearance.showSpeed = b }
        }

        if root.contains(key: "snippet") {
            if let list = try? root.array(forKey: "snippet") {
                for i in 0..<list.count {
                    let label = "snippet #\(i + 1)"
                    guard let t = try? list.table(atIndex: i) else { issues.append(.warning("\(label): use [[snippet]] blocks")); continue }
                    warnUnknownKeys(t, known: ["name", "keyword", "text", "hotkey"], in: label, &issues)
                    guard let name = try? t.string(forKey: "name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                        issues.append(.warning("\(label): missing name, skipped")); continue
                    }
                    guard let text = try? t.string(forKey: "text"), !text.isEmpty else {
                        issues.append(.warning("\(label) '\(name)': missing text, skipped")); continue
                    }
                    var keyword: String?
                    if t.contains(key: "keyword") {
                        if let k = try? t.string(forKey: "keyword"), !k.isEmpty, !k.contains(" ") { keyword = k }
                        else { issues.append(.warning("\(label) '\(name)': keyword can't be empty or contain spaces")) }
                    }
                    config.snippets.append(Snippet(name: name, keyword: keyword, text: text))
                    if let h = commandHotkey(t, target: name, kind: .snippet, in: "\(label) '\(name)'", &issues) {
                        config.commandHotkeys.append(h)
                    }
                }
            } else {
                issues.append(.warning("snippets must be [[snippet]] blocks"))
            }
        }

        if let t = table(root, "expansion", &issues) {
            warnUnknownKeys(t, known: ["enabled"], in: "[expansion]", &issues)
            if let b = bool(t, "enabled", in: "expansion", &issues) { config.expansionEnabled = b }
        }

        if let t = table(root, "hotkeys", &issues) {
            for target in t.keys.sorted() {
                guard !target.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if let h = commandHotkey(t, key: target, target: target, kind: nil, in: "hotkeys", &issues) {
                    config.commandHotkeys.append(h)
                }
            }
        }

        if let t = table(root, "pages", &issues) {
            warnUnknownKeys(t, known: ["enabled", "limit", "exclude_hosts"], in: "[pages]", &issues)
            if let b = bool(t, "enabled", in: "pages", &issues) { config.pagesEnabled = b }
            if t.contains(key: "limit") {
                if let n = try? t.integer(forKey: "limit"), (1...5_000).contains(n) { config.pagesLimit = Int(n) }
                else { issues.append(.warning("pages.limit must be a number from 1 to 5000")) }
            }
            if let a = strings(t, "exclude_hosts", in: "pages", &issues) { config.pagesExcludedHosts = a.map { $0.lowercased() } }
        }

        if let t = table(root, "obsidian", &issues) {
            warnUnknownKeys(t, known: ["vault"], in: "[obsidian]", &issues)
            if t.contains(key: "vault") {
                if let s = try? t.string(forKey: "vault") { config.obsidianVault = s.isEmpty ? nil : s }
                else { issues.append(.warning("obsidian.vault must be a folder path, e.g. \"~/Notes\"")) }
            }
        }

        if let t = table(root, "bitbucket", &issues) {
            warnUnknownKeys(t, known: ["enabled", "base_url", "email", "token_command", "repos", "refresh_minutes"], in: "[bitbucket]", &issues)
            var b = config.bitbucket ?? BitbucketSettings()
            if t.contains(key: "base_url") {
                if let s = try? t.string(forKey: "base_url"), let u = URL(string: s), u.scheme == "https" {
                    b.baseURL = s.hasSuffix("/") ? String(s.dropLast()) : s
                } else { issues.append(.warning("bitbucket.base_url must be an https URL")) }
            }
            if t.contains(key: "email") {
                if let s = try? t.string(forKey: "email") { b.email = s } else { issues.append(.warning("bitbucket.email must be a string")) }
            }
            if t.contains(key: "token_command") {
                if let s = try? t.string(forKey: "token_command"), !s.trimmingCharacters(in: .whitespaces).isEmpty { b.tokenCommand = s }
                else { issues.append(.warning("bitbucket.token_command must be a command that prints your token")) }
            }
            if let a = strings(t, "repos", in: "bitbucket", &issues) {
                b.repos = a.filter { r in
                    let ok = r.split(separator: "/").count == 2
                    if !ok { issues.append(.warning("bitbucket.repos: '\(r)' should be \"workspace/repo\"")) }
                    return ok
                }
            }
            if t.contains(key: "refresh_minutes") {
                if let n = try? t.integer(forKey: "refresh_minutes"), (1...120).contains(n) { b.refreshMinutes = Int(n) }
                else { issues.append(.warning("bitbucket.refresh_minutes must be a number from 1 to 120")) }
            }
            let enabled = bool(t, "enabled", in: "bitbucket", &issues) ?? true
            config.bitbucket = enabled ? b : nil // email is checked after includes are merged
        }

        if let t = table(root, "jira", &issues) {
            warnUnknownKeys(t, known: ["enabled", "base_url", "email", "token_command", "jql", "recent", "refresh_minutes"], in: "[jira]", &issues)
            var j = config.jira ?? JiraSettings()
            if t.contains(key: "base_url") {
                if let s = try? t.string(forKey: "base_url"), let u = URL(string: s), u.scheme == "https", u.host != nil {
                    j.baseURL = s.hasSuffix("/") ? String(s.dropLast()) : s
                } else { issues.append(.warning("jira.base_url must be an https URL, e.g. \"https://your-site.atlassian.net\"")) }
            }
            if t.contains(key: "email") {
                if let s = try? t.string(forKey: "email") { j.email = s } else { issues.append(.warning("jira.email must be a string")) }
            }
            if t.contains(key: "token_command") {
                if let s = try? t.string(forKey: "token_command"), !s.trimmingCharacters(in: .whitespaces).isEmpty { j.tokenCommand = s }
                else { issues.append(.warning("jira.token_command must be a command that prints your token")) }
            }
            if t.contains(key: "jql") {
                if let s = try? t.string(forKey: "jql"), !s.trimmingCharacters(in: .whitespaces).isEmpty { j.jql = s }
                else { issues.append(.warning("jira.jql must be a JQL query")) }
            }
            if let b = bool(t, "recent", in: "jira", &issues) { j.recent = b }
            if t.contains(key: "refresh_minutes") {
                if let n = try? t.integer(forKey: "refresh_minutes"), (1...120).contains(n) { j.refreshMinutes = Int(n) }
                else { issues.append(.warning("jira.refresh_minutes must be a number from 1 to 120")) }
            }
            let enabled = bool(t, "enabled", in: "jira", &issues) ?? true
            config.jira = enabled ? j : nil // base_url and email are checked after includes are merged
        }

        if let t = table(root, "mods", &issues) {
            warnUnknownKeys(t, known: ["agent"], in: "[mods]", &issues)
            if t.contains(key: "agent") {
                if let s = try? t.string(forKey: "agent"), !s.trimmingCharacters(in: .whitespaces).isEmpty { config.modAgent = s }
                else { issues.append(.warning("mods.agent must be a command, e.g. \"claude\" or \"codex\"")) }
            }
        }
        if let t = table(root, "agents", &issues) {
            warnUnknownKeys(t, known: ["share"], in: "[agents]", &issues)
            if let a = strings(t, "share", in: "agents", &issues) {
                var share = Set<AgentTools.Source>()
                for name in a {
                    if let s = AgentTools.Source(rawValue: name.lowercased()) { share.insert(s) }
                    else { issues.append(.warning("agents.share: unknown source '\(name)' (use \(AgentTools.Source.allCases.map(\.rawValue).joined(separator: ", ")))")) }
                }
                config.agentShare = share
            }
        }

        if let t = table(root, "plugins", &issues) {
            warnUnknownKeys(t, known: ["paths", "disabled"], in: "[plugins]", &issues)
            if let a = strings(t, "paths", in: "plugins", &issues) { config.pluginPaths += a }
            if let a = strings(t, "disabled", in: "plugins", &issues) { config.pluginsDisabled.formUnion(a) }
        }

        if let t = table(root, "plugin", &issues) {
            for id in t.keys.sorted() {
                guard let sub = try? t.table(forKey: id) else {
                    issues.append(.warning("plugin.\(id) must be a table: [plugin.\(id)]")); continue
                }
                let values = PluginLoader.settings(sub, in: "[plugin.\(id)]", &issues)
                config.pluginSettings[id, default: [:]].merge(values) { $1 }
            }
        }

        if let t = table(root, "updates", &issues) {
            warnUnknownKeys(t, known: ["check", "auto_install", "channel"], in: "[updates]", &issues)
            if let b = bool(t, "check", in: "updates", &issues) { config.updates.check = b }
            if let b = bool(t, "auto_install", in: "updates", &issues) { config.updates.autoInstall = b }
            if t.contains(key: "channel") {
                if let s = try? t.string(forKey: "channel"), let c = UpdateSettings.Channel(rawValue: s) { config.updates.channel = c }
                else { issues.append(.warning("updates.channel must be \"stable\" or \"dev\"")) }
            }
            if config.updates.autoInstall && !config.updates.check {
                if t.contains(key: "auto_install") { issues.append(.warning("updates.auto_install needs updates.check = true")) }
                config.updates.autoInstall = false
            }
        }
    }

    static func parseAction(_ t: TOMLTable, label: String, _ issues: inout [ConfigIssue]) -> Action? {
        warnUnknownKeys(t, known: ["name", "run", "output", "alias", "hotkey"], in: label, &issues)
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

    /// `t[key]` as a hotkey for `target`, if present; a warning if it doesn't parse.
    private static func commandHotkey(_ t: TOMLTable, key: String = "hotkey", target: String, kind: CommandHotkey.Kind?,
                                      in place: String, _ issues: inout [ConfigIssue]) -> CommandHotkey? {
        guard t.contains(key: key) else { return nil }
        let label = kind == nil ? "\(place).\(key)" : "\(place): hotkey"
        guard let s = try? t.string(forKey: key) else {
            issues.append(.warning("\(label) must be a string like \"ctrl+opt+t\"")); return nil
        }
        switch HotkeySpec.parse(s) {
        case .success(let spec): return CommandHotkey(hotkey: spec, target: target, kind: kind)
        case .failure(let e): issues.append(.warning("\(label): \(e.message)")); return nil
        }
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

    static func warnUnknownKeys(_ t: TOMLTable, known: Set<String>, in place: String, _ issues: inout [ConfigIssue]) {
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
        return try parse(text, directory: url.deletingLastPathComponent())
    }
}
