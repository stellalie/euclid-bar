import Foundation

/// One row a plugin prints: a JSON object per line. Only `title` is required.
///
///     {"title":"Fix login","subtitle":"acme/web · #412","open":"https://…","label":"Review","suggest":true}
///
/// `↵` does the first of `open` (a URL or path), `paste`, `copy` or `run` (a shell command
/// in the plugin's folder) that is set. `⌘C` copies `copy`, else `open`.
public struct PluginItem: Equatable, Sendable, Decodable {
    public var title: String
    public var subtitle: String?
    public var open: String?
    public var copy: String?
    public var paste: String?
    public var run: String?
    /// SF Symbol name, e.g. "arrow.triangle.pull".
    public var icon: String?
    /// Shown on the right; defaults to the plugin's name.
    public var label: String?
    /// Text for the preview pane (→).
    public var preview: String?
    /// Stable identity for learned ranking; defaults to `open`, then `title`.
    public var id: String?
    /// Also list it when the search box is empty (at most 3 per plugin).
    public var suggest: Bool?
    /// Up to 3 fields to fill in before ↵ runs it; their values reach `run` as `$1`–`$3`.
    public var arguments: [PluginArgument]?
    /// More things to do with it, shown by ⌘K: items like this one (without their own `actions`).
    /// The first is what ↵ does when the item itself has no `open`, `paste`, `copy` or `run`.
    public var actions: [PluginItem]?

    public static let maxActions = 20

    public init(title: String, subtitle: String? = nil, open: String? = nil, copy: String? = nil, paste: String? = nil,
                run: String? = nil, icon: String? = nil, label: String? = nil, preview: String? = nil,
                id: String? = nil, suggest: Bool? = nil, arguments: [PluginArgument]? = nil, actions: [PluginItem]? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.open = open
        self.copy = copy
        self.paste = paste
        self.run = run
        self.icon = icon
        self.label = label
        self.preview = preview
        self.id = id
        self.suggest = suggest
        self.arguments = arguments.map { Array($0.prefix(PluginArgument.max)) }
        let actions = (actions ?? []).prefix(Self.maxActions).map { var a = $0; a.actions = nil; return a }
        self.actions = actions.isEmpty ? nil : Array(actions)
    }

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, open, copy, paste, run, icon, label, preview, id, suggest, arguments, actions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: try c.decode(String.self, forKey: .title),
                  subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle),
                  open: try c.decodeIfPresent(String.self, forKey: .open),
                  copy: try c.decodeIfPresent(String.self, forKey: .copy),
                  paste: try c.decodeIfPresent(String.self, forKey: .paste),
                  run: try c.decodeIfPresent(String.self, forKey: .run),
                  icon: try c.decodeIfPresent(String.self, forKey: .icon),
                  label: try c.decodeIfPresent(String.self, forKey: .label),
                  preview: try c.decodeIfPresent(String.self, forKey: .preview),
                  id: try c.decodeIfPresent(String.self, forKey: .id),
                  suggest: try c.decodeIfPresent(Bool.self, forKey: .suggest),
                  arguments: try c.decodeIfPresent([PluginArgument].self, forKey: .arguments),
                  actions: try c.decodeIfPresent([PluginItem].self, forKey: .actions))
    }

    /// Fields to fill in before ↵ runs it (only with `run`).
    public var fields: [PluginArgument] { run == nil ? [] : arguments ?? [] }

    public var key: String { id ?? open ?? title }

    public func searchItem(id: Int) -> SearchItem {
        SearchItem(id: id, title: title, subtitle: subtitle ?? "", searchText: "\(title) \(subtitle ?? "")")
    }
}

/// A field an item asks for before it runs, like a Raycast script's `@raycast.argument1`:
///
///     {"type":"text","placeholder":"City"}
///     {"type":"dropdown","placeholder":"Unit","data":[{"title":"Celsius","value":"c"}]}
public struct PluginArgument: Equatable, Sendable, Decodable {
    public static let max = 3

    public enum Kind: String, Equatable, Sendable, Decodable {
        case text, password, dropdown
    }

    public struct Choice: Equatable, Sendable, Decodable {
        public var title: String
        public var value: String

        public init(title: String, value: String) {
            self.title = title
            self.value = value
        }

        private enum CodingKeys: String, CodingKey { case title, value }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let value = try c.decode(String.self, forKey: .value)
            self.init(title: try c.decodeIfPresent(String.self, forKey: .title) ?? value, value: value)
        }
    }

    public var type: Kind
    public var placeholder: String
    /// Optional fields may be left empty (they're passed as "").
    public var optional: Bool
    /// A dropdown's choices: the field shows `title`, the script gets `value`.
    public var data: [Choice]

    public init(type: Kind = .text, placeholder: String = "", optional: Bool = false, data: [Choice] = []) {
        self.type = type
        self.placeholder = placeholder
        self.optional = optional
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case type, placeholder, optional, data }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: try c.decodeIfPresent(Kind.self, forKey: .type) ?? .text,
                  placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder) ?? "",
                  optional: try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false,
                  data: try c.decodeIfPresent([Choice].self, forKey: .data) ?? [])
    }

    /// What the script gets for `typed`: a dropdown's value for the title you picked (or typed),
    /// nil when it can't run like this (a required field is empty, or no such choice).
    public func value(for typed: String) -> String? {
        let t = typed.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return optional ? "" : nil }
        guard type == .dropdown, !data.isEmpty else { return typed }
        return (data.first { $0.title.caseInsensitiveCompare(t) == .orderedSame }
            ?? data.first { $0.value.caseInsensitiveCompare(t) == .orderedSame })?.value
    }
}

public enum PluginOutput {
    /// Most rows a plugin can add, so a runaway script can't flood search.
    public static let maxItems = 2_000

    /// JSON lines (or one JSON array). Blank lines are skipped; bad lines become problems.
    public static func parse(_ data: Data) -> (items: [PluginItem], problems: [String]) {
        let decoder = JSONDecoder()
        var items: [PluginItem] = [], problems: [String] = []
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            do { items = try decoder.decode([PluginItem].self, from: Data(trimmed.utf8)) }
            catch { problems.append("output is a JSON array but not a list of items with a title") }
        } else {
            for (n, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                let line = line.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                guard line.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    problems.append("line \(n + 1): not a JSON object"); continue
                }
                guard json["title"] is String else { problems.append("line \(n + 1): missing \"title\""); continue }
                guard let item = try? decoder.decode(PluginItem.self, from: Data(line.utf8)) else {
                    problems.append("line \(n + 1): a field has the wrong type (all are strings, suggest is true/false, arguments a list)"); continue
                }
                items.append(item)
                if items.count == maxItems { problems.append("stopped at \(maxItems) items"); break }
            }
        }
        items.removeAll { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        return (Array(items.prefix(maxItems)), problems)
    }
}

extension PluginItem {
    /// The row a plugin shows in search while its list can't load (and it has nothing older to show),
    /// so typing its name says why instead of finding nothing. ↵ opens the plugin's folder.
    public static func failed(_ plugin: Plugin, _ error: Error) -> PluginItem {
        let missing = (error as? PluginRunner.Failure)?.missingCommand
        let title = missing.map { "\(plugin.name): `\($0)` isn't installed" } ?? "\(plugin.name) couldn't load"
        let subtitle = missing != nil
            ? "Install it, or add its folder to PATH under [env] in config.toml"
            : String(describing: error)
        return PluginItem(title: title, subtitle: subtitle, open: plugin.directory,
                          icon: "exclamationmark.triangle", label: "Problem", preview: String(describing: error),
                          id: "problem:\(plugin.id)")
    }
}
