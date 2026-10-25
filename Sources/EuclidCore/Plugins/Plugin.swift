import Foundation
import TOMLDecoder

/// A plugin: a folder with a `plugin.toml` and whatever scripts it runs.
///
///     ~/.config/euclid/plugins/github/
///       plugin.toml      name, [source] / [answer] / [badge] / [[action]], [settings]
///       prs.sh           prints one JSON object per line (see `PluginItem`)
///
/// Nothing is compiled or sandboxed: a plugin is shell commands you can read, run in
/// its own folder with `$EUCLID_PLUGIN_DIR` and its settings as `$EUCLID_SETTING_<KEY>`.
public struct Plugin: Equatable, Sendable {
    /// The folder name; `[plugin.<id>]` in config.toml overrides its settings.
    public let id: String
    public let name: String
    public let description: String
    /// Absolute path of the plugin's folder.
    public let directory: String
    /// Items for search, refreshed in the background.
    public var source: Source?
    /// Replies to what you type, below the instant results.
    public var answer: Answer?
    /// A short status on the search bar ("1.2M tok"); clicking it runs `click`.
    public var badge: Badge?
    /// Added to your actions, after config.toml's and included ones.
    public var actions: [Action] = []
    /// `[[on]]`: commands Euclid runs when something happens (a copy, the panel opening…).
    public var hooks: [Hook] = []
    /// `[[key]]`: shortcuts in the panel that act on the selected result.
    public var keys: [Key] = []
    /// Defaults from plugin.toml, with config.toml's `[plugin.<id>]` on top.
    public var settings: [String: String] = [:]
    /// Changes when any file in the folder does, so an edited script reruns.
    public var revision = ""

    public struct Source: Equatable, Sendable {
        public let run: String
        public let refreshMinutes: Int
    }

    public struct Badge: Equatable, Sendable {
        public let run: String
        public let refreshMinutes: Int
        /// SF Symbol shown before the text.
        public let icon: String?
        public let click: String?

        /// The first non-empty line of the command's output, kept short.
        public static func text(from output: Data) -> String? {
            let line = String(decoding: output.prefix(4096), as: UTF8.self)
                .split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            guard let line else { return nil }
            return line.count > 40 ? String(line.prefix(39)) + "…" : line
        }
    }

    public struct Answer: Equatable, Sendable {
        public let run: String
        /// `tz 3pm` → runs with "3pm" when the prefix is "tz".
        public let prefix: String?
        /// Or: runs with the whole query when it matches this regex.
        public let match: String?

        /// What the command gets as `$1` for this query, or nil when it doesn't apply.
        public func input(for query: String) -> String? {
            let q = query.trimmingCharacters(in: .whitespaces)
            if let prefix {
                let lower = q.lowercased(), p = prefix.lowercased() + " "
                if lower.hasPrefix(p) {
                    let rest = q.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
                    return rest.isEmpty ? nil : rest
                }
            }
            if let match, !q.isEmpty, q.range(of: match, options: .regularExpression) != nil { return q }
            return nil
        }
    }

    /// What a hook reacts to. `$1` is in brackets.
    public enum Event: String, CaseIterable, Sendable {
        /// You copied text (the text).
        case clipboard
        /// The panel opened (the app you were in).
        case open
        /// You picked a result with ↵ (its URL, path or text; `$EUCLID_ITEM_*` has the rest).
        case choose
        /// You switched to another app (its name).
        case app
    }

    public struct Hook: Equatable, Sendable {
        public let event: Event
        public let run: String

        public init(event: Event, run: String) {
            self.event = event
            self.run = run
        }
    }

    public struct Key: Equatable, Sendable {
        public let key: HotkeySpec
        /// Shown in the footer when the key applies.
        public let name: String
        public let run: String
        /// Kinds of result it applies to ("file", "pr", or a plugin's id); empty = any.
        public let when: [String]

        public init(key: HotkeySpec, name: String, run: String, when: [String] = []) {
            self.key = key
            self.name = name
            self.run = run
            self.when = when
        }

        public func applies(to item: ModItem) -> Bool {
            when.isEmpty || when.contains(item.kind) || item.pluginID.map(when.contains) == true
        }
    }

    /// For every command the plugin runs.
    public var environment: [String: String] {
        var env = ["EUCLID_PLUGIN_DIR": directory]
        for (key, value) in settings { env["EUCLID_SETTING_" + key.uppercased()] = value }
        return env
    }
}

public enum PluginLoader {
    public static let manifestName = "plugin.toml"

    /// Every `<dir>/<id>/plugin.toml` under `directories`, in order; the first plugin with an id wins.
    /// Also returns what to watch so a plugin reloads on save: the plugin folders and the files in them.
    public static func load(directories: [String], disabled: Set<String>, overrides: [String: [String: String]],
                            _ issues: inout [ConfigIssue]) -> (plugins: [Plugin], watched: [String]) {
        let fm = FileManager.default
        var plugins: [Plugin] = [], watched: [String] = [], seen = Set<String>()
        for dir in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for id in names.sorted() where !id.hasPrefix(".") {
                let folder = (dir as NSString).appendingPathComponent(id)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { continue }
                watched.append(folder) // a plugin.toml written here later loads it
                let manifest = (folder as NSString).appendingPathComponent(manifestName)
                guard fm.fileExists(atPath: manifest), seen.insert(id).inserted else { continue }
                let files = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted().filter { !$0.hasPrefix(".") }.prefix(50)
                    .map { (folder as NSString).appendingPathComponent($0) }
                watched += files
                guard !disabled.contains(id) else { continue }
                guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else {
                    issues.append(.warning("plugin \(id): can't read plugin.toml")); continue
                }
                var own: [ConfigIssue] = []
                if var plugin = parse(text, id: id, directory: folder, &own) {
                    for (key, value) in overrides[id] ?? [:] { plugin.settings[key] = value }
                    plugin.revision = files.map { path in
                        let a = try? fm.attributesOfItem(atPath: path)
                        let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                        return "\((path as NSString).lastPathComponent):\(mtime):\(a?[.size] ?? 0)"
                    }.joined(separator: "|")
                    plugins.append(plugin)
                }
                issues += own.map { .init(severity: $0.severity, message: "plugin \(id): \($0.message)") }
            }
        }
        for id in overrides.keys.sorted() where !seen.contains(id) {
            issues.append(.warning("[plugin.\(id)]: no plugin named '\(id)' is installed"))
        }
        return (plugins, watched)
    }

    /// One plugin.toml. Nil when it can't be used at all; smaller problems become issues.
    public static func parse(_ text: String, id: String, directory: String, _ issues: inout [ConfigIssue]) -> Plugin? {
        let root: TOMLTable
        do { root = try TOMLTable(source: text) } catch {
            issues.append(.warning("plugin.toml isn't valid TOML: \(error)")); return nil
        }
        ConfigLoader.warnUnknownKeys(root, known: ["name", "description", "source", "answer", "badge", "action", "on", "key", "settings"], in: "plugin.toml", &issues)
        let name = (try? root.string(forKey: "name")).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? id
        let description = (try? root.string(forKey: "description")) ?? ""
        var plugin = Plugin(id: id, name: name, description: description, directory: directory)

        if root.contains(key: "settings") {
            if let t = try? root.table(forKey: "settings") { plugin.settings = settings(t, in: "[settings]", &issues) }
            else { issues.append(.warning("settings must be a table: [settings]")) }
        }

        if root.contains(key: "source") {
            if let t = try? root.table(forKey: "source") {
                ConfigLoader.warnUnknownKeys(t, known: ["run", "refresh_minutes"], in: "[source]", &issues)
                var refresh = 10
                if t.contains(key: "refresh_minutes") {
                    if let n = try? t.integer(forKey: "refresh_minutes"), (1...1440).contains(n) { refresh = Int(n) }
                    else { issues.append(.warning("source.refresh_minutes must be a number from 1 to 1440")) }
                }
                if let run = command(t, "source", &issues) { plugin.source = .init(run: run, refreshMinutes: refresh) }
            } else { issues.append(.warning("source must be a table: [source]")) }
        }

        if root.contains(key: "answer") {
            if let t = try? root.table(forKey: "answer") {
                ConfigLoader.warnUnknownKeys(t, known: ["run", "prefix", "match"], in: "[answer]", &issues)
                var prefix: String?, match: String?
                if t.contains(key: "prefix") {
                    if let s = try? t.string(forKey: "prefix"), !s.isEmpty, !s.contains(" ") { prefix = s }
                    else { issues.append(.warning("answer.prefix must be one word, e.g. \"tz\"")) }
                }
                if t.contains(key: "match") {
                    if let s = try? t.string(forKey: "match"), (try? NSRegularExpression(pattern: s)) != nil { match = s }
                    else { issues.append(.warning("answer.match must be a regular expression")) }
                }
                if let run = command(t, "answer", &issues) {
                    if prefix == nil && match == nil {
                        // Running a command on every keystroke would cost every search; ask for a trigger.
                        issues.append(.warning("[answer] needs a prefix or a match, so it doesn't run on every search; skipped"))
                    } else {
                        plugin.answer = .init(run: run, prefix: prefix, match: match)
                    }
                }
            } else { issues.append(.warning("answer must be a table: [answer]")) }
        }

        if root.contains(key: "badge") {
            if let t = try? root.table(forKey: "badge") {
                ConfigLoader.warnUnknownKeys(t, known: ["run", "refresh_minutes", "icon", "click"], in: "[badge]", &issues)
                var refresh = 5
                if t.contains(key: "refresh_minutes") {
                    if let n = try? t.integer(forKey: "refresh_minutes"), (1...1440).contains(n) { refresh = Int(n) }
                    else { issues.append(.warning("badge.refresh_minutes must be a number from 1 to 1440")) }
                }
                let icon = (try? t.string(forKey: "icon")).flatMap { $0.isEmpty ? nil : $0 }
                var click: String?
                if t.contains(key: "click") {
                    if let s = try? t.string(forKey: "click"), !s.trimmingCharacters(in: .whitespaces).isEmpty { click = s }
                    else { issues.append(.warning("badge.click must be a command, e.g. 'ghostty-run tab ccusage'")) }
                }
                if let run = command(t, "badge", &issues) {
                    plugin.badge = .init(run: run, refreshMinutes: refresh, icon: icon, click: click)
                }
            } else { issues.append(.warning("badge must be a table: [badge]")) }
        }

        if root.contains(key: "action") {
            if let list = try? root.array(forKey: "action") {
                for i in 0..<list.count {
                    guard let t = try? list.table(atIndex: i),
                          let a = ConfigLoader.parseAction(t, label: "action #\(i + 1)", &issues) else { continue }
                    plugin.actions.append(a)
                }
            } else { issues.append(.warning("actions must be [[action]] blocks")) }
        }

        for (i, t) in tables(root, "on", &issues).enumerated() {
            let label = "on #\(i + 1)"
            ConfigLoader.warnUnknownKeys(t, known: ["event", "run"], in: label, &issues)
            let name = (try? t.string(forKey: "event")) ?? ""
            guard let event = Plugin.Event(rawValue: name.lowercased()) else {
                issues.append(.warning("\(label): event must be one of \(Plugin.Event.allCases.map(\.rawValue).joined(separator: ", "))")); continue
            }
            if let run = command(t, label, &issues) { plugin.hooks.append(.init(event: event, run: run)) }
        }

        for (i, t) in tables(root, "key", &issues).enumerated() {
            let label = "key #\(i + 1)"
            ConfigLoader.warnUnknownKeys(t, known: ["key", "name", "run", "when"], in: label, &issues)
            let text = (try? t.string(forKey: "key")) ?? ""
            let spec: HotkeySpec
            switch HotkeySpec.parse(text) {
            case .success(let s): spec = s
            case .failure(let e): issues.append(.warning("\(label): key: \(e.message)")); continue
            }
            if let taken = reservedKeys[spec] {
                issues.append(.warning("\(label): \(spec.symbols) is Euclid's \(taken); pick another key")); continue
            }
            var when: [String] = []
            if t.contains(key: "when") {
                if let s = try? t.string(forKey: "when") { when = [s] }
                else if let a = try? t.array(forKey: "when") { when = (0..<a.count).compactMap { try? a.string(atIndex: $0) } }
                else { issues.append(.warning("\(label): when must be a kind or a list, e.g. [\"file\", \"project\"]")) }
            }
            let name = (try? t.string(forKey: "name")).flatMap { $0.isEmpty ? nil : $0 } ?? plugin.name
            if let run = command(t, label, &issues) { plugin.keys.append(.init(key: spec, name: name, run: run, when: when.map { $0.lowercased() })) }
        }

        if plugin.source == nil, plugin.answer == nil, plugin.badge == nil, plugin.actions.isEmpty, plugin.hooks.isEmpty, plugin.keys.isEmpty {
            issues.append(.warning("has no [source], [answer], [badge], [[action]], [[on]] or [[key]], so it does nothing"))
        }
        return plugin
    }

    /// `[settings]` / `[plugin.<id>]`: strings, numbers and booleans, passed on as text.
    static func settings(_ t: TOMLTable, in place: String, _ issues: inout [ConfigIssue]) -> [String: String] {
        var out: [String: String] = [:]
        for key in t.keys.sorted() {
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                issues.append(.warning("\(place): '\(key)' must be letters, digits and _")); continue
            }
            if let s = try? t.string(forKey: key) { out[key] = s }
            else if let n = try? t.integer(forKey: key) { out[key] = String(n) }
            else if let b = try? t.bool(forKey: key) { out[key] = String(b) }
            else { issues.append(.warning("\(place).\(key) must be a string, number or true/false")) }
        }
        return out
    }

    /// `[[name]]` blocks (a single `[name]` table counts as one).
    private static func tables(_ root: TOMLTable, _ name: String, _ issues: inout [ConfigIssue]) -> [TOMLTable] {
        guard root.contains(key: name) else { return [] }
        if let list = try? root.array(forKey: name) { return (0..<list.count).compactMap { try? list.table(atIndex: $0) } }
        if let t = try? root.table(forKey: name) { return [t] }
        issues.append(.warning("\(name) must be [[\(name)]] blocks")); return []
    }

    /// Keys the panel already uses; a plugin can't take them.
    static let reservedKeys: [HotkeySpec: String] = {
        var keys: [HotkeySpec: String] = [:]
        func add(_ text: String, _ what: String) { if case .success(let s) = HotkeySpec.parse(text) { keys[s] = what } }
        add("cmd+k", "actions"); add("cmd+y", "preview"); add("cmd+c", "copy"); add("cmd+shift+c", "copy branch")
        add("cmd+return", "first action"); add("cmd+a", "select all"); add("cmd+x", "cut"); add("cmd+v", "paste")
        add("cmd+z", "undo"); add("cmd+q", "quit"); add("cmd+w", "close"); add("cmd+h", "hide")
        for n in 0...9 { add("cmd+\(n)", "action \(n)") }
        return keys
    }()

    private static func command(_ t: TOMLTable, _ place: String, _ issues: inout [ConfigIssue]) -> String? {
        if let s = try? t.string(forKey: "run"), !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        issues.append(.warning("\(place).run must be a command, e.g. './items.sh'"))
        return nil
    }
}
