import Foundation

/// One source the search can be narrowed to with ⇥ ("Clipboard"), or a plugin's items.
public enum SearchScope: Hashable, Sendable {
    case apps, files, clipboard, history, projects, snippets, notes, actions
    /// A plugin's source items, by plugin id.
    case plugin(id: String, name: String)

    /// Built-in sources, in ⇥ order.
    public static let builtIn: [SearchScope] = [.apps, .files, .clipboard, .history, .projects, .snippets, .notes, .actions]

    public var title: String {
        switch self {
        case .apps: "Apps"
        case .files: "Files"
        case .clipboard: "Clipboard"
        case .history: "History"
        case .projects: "Projects"
        case .snippets: "Snippets"
        case .notes: "Notes"
        case .actions: "Actions"
        case .plugin(_, let name): name
        }
    }

    /// SF Symbol for the chip.
    public var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .files: "doc"
        case .clipboard: "clipboard"
        case .history: "clock.arrow.circlepath"
        case .projects: "folder"
        case .snippets: "text.quote"
        case .notes: "note.text"
        case .actions: "bolt"
        case .plugin: "puzzlepiece.extension"
        }
    }

    /// What `[search] scopes` values and typed names call it.
    public var id: String {
        switch self {
        case .plugin(let id, _): id
        default: title.lowercased()
        }
    }

    /// Extra words that pick it when typed before ⇥.
    var aliases: [String] {
        switch self {
        case .apps: ["app", "applications"]
        case .files: ["file", "finder"]
        case .clipboard: ["clip", "clips", "copied"]
        case .history: ["browser", "web", "urls"]
        case .projects: ["project", "repos", "git"]
        case .snippets: ["snippet", "snip"]
        case .notes: ["note", "pages", "obsidian"]
        case .actions: ["action"]
        case .plugin: []
        }
    }

    /// The scope a typed word names: its id, an alias, or a 3+ letter start of its title,
    /// among `scopes` (so plugins count). Nil when it names none, or more than one by prefix.
    public static func named(_ text: String, among scopes: [SearchScope]) -> SearchScope? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if let exact = scopes.first(where: { $0.id == t || $0.title.lowercased() == t || $0.aliases.contains(t) }) { return exact }
        guard t.count >= 3 else { return nil }
        let starts = scopes.filter { $0.title.lowercased().hasPrefix(t) }
        return starts.count == 1 ? starts[0] : nil
    }

    /// ⇥ from `current` (nil = everything): the next scope, wrapping back to everything.
    public static func next(after current: SearchScope?, in scopes: [SearchScope], backwards: Bool = false) -> SearchScope? {
        let all: [SearchScope?] = [nil] + scopes
        let i = all.firstIndex(of: current) ?? 0
        return all[(i + (backwards ? all.count - 1 : 1)) % all.count]
    }

    /// `[search] scopes = { c = "clipboard" }`: "c kube" → (.clipboard, "kube").
    public static func prefixed(_ text: String, prefixes: [String: String], among scopes: [SearchScope]) -> (SearchScope, String)? {
        guard !prefixes.isEmpty, let space = text.firstIndex(of: " ") else { return nil }
        let word = String(text[..<space]).lowercased()
        guard let target = prefixes[word], let scope = scopes.first(where: { $0.id == target.lowercased() }) else { return nil }
        return (scope, String(text[text.index(after: space)...]))
    }
}

/// One footer tip in the empty bar, retired once you've used what it shows.
public struct Tip: Equatable, Sendable {
    /// What using it records (`Tips.record`): "answers", "filter", "preview", "actions", "first-action", "shortcuts".
    public let feature: String
    public let text: String
    /// Things to type, drawn as code after `text`.
    public let examples: [String]

    public init(feature: String, text: String, examples: [String] = []) {
        self.feature = feature
        self.text = text
        self.examples = examples
    }
}

public enum Tips {
    public static let all: [Tip] = [
        Tip(feature: "answers", text: "Try", examples: ["12*7", "#7c5cff", "1697040000"]),
        Tip(feature: "filter", text: "⇥ narrows to one source: Apps, Files, Clipboard…"),
        Tip(feature: "preview", text: "→ previews the selected result"),
        Tip(feature: "actions", text: "⌘K shows everything you can do with a result"),
        Tip(feature: "first-action", text: "⌘↵ runs your first action on what you typed"),
        Tip(feature: "shortcuts", text: "⌘/ lists every shortcut, source and keyword"),
    ]

    /// The tip for the `opens`-th time the panel opens: rotates through the ones whose feature isn't in `used`.
    public static func pick(opens: Int, used: Set<String>) -> Tip? {
        let left = all.filter { !used.contains($0.feature) }
        return left.isEmpty ? nil : left[max(0, opens) % left.count]
    }
}

/// ⌘/: every key, source, prefix and keyword in one list, built from config so it's always current.
public enum CheatSheet {
    public static let keys: [(String, String)] = [
        ("↵", "Open, paste or run the selected result"),
        ("⌘↵", "Run your first action on what you typed"),
        ("⌘1–⌘9", "Run action 1–9"),
        ("⌘K", "Actions for the selected result"),
        ("→  ⌘Y", "Preview the selected result"),
        ("⌘C", "Copy the result (text, URL or path)"),
        ("⌘⌫", "Delete a clipboard item"),
        ("⇥  ⇧⇥", "Narrow to one source, or the next one"),
        ("⌫", "On an empty search: back to every source"),
        ("esc", "Close the preview, the filter, a view, then the bar"),
        ("⌘/", "This list"),
    ]

    public static func text(scopes: [SearchScope], prefixes: [String: String] = [:], actions: [String] = [],
                            aliases: [(alias: String, target: String)] = [], snippets: [(keyword: String, name: String)] = [],
                            pluginKeys: [(key: String, name: String)] = []) -> String {
        var sections: [(String, [(String, String)])] = [("Keys", keys)]
        let filters = scopes.map { scope in
            let typed = prefixes.filter { $0.value.lowercased() == scope.id }.keys.sorted().map { "\($0) …" }
            return (scope.title, (["\(scope.id) ⇥"] + typed).joined(separator: "  or  "))
        }
        sections.append(("Sources (type the name, then ⇥)", filters))
        sections.append(("Answers (just type them)", [
            ("12*7", "Calculator"), ("#7c5cff", "Colour, with a swatch"), ("1697040000", "Epoch → date"),
            ("{\"a\":1}", "JSON, pretty or minified"),
        ]))
        if !actions.isEmpty {
            sections.append(("Actions", actions.enumerated().map { ($0.offset < 9 ? "⌘\($0.offset + 1)" : "⌘K", $0.element) }))
        }
        if !aliases.isEmpty { sections.append(("Aliases", aliases.map { ($0.alias, $0.target) })) }
        if !snippets.isEmpty { sections.append(("Snippet keywords", snippets.map { ($0.keyword, $0.name) })) }
        if !pluginKeys.isEmpty { sections.append(("Plugin keys", pluginKeys.map { ($0.key, $0.name) })) }

        let width = sections.flatMap(\.1).map(\.0.count).max() ?? 0
        return sections.filter { !$0.1.isEmpty }.map { title, rows in
            ([title] + rows.map { $0.0.padding(toLength: width + 3, withPad: " ", startingAt: 0) + $0.1 }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
