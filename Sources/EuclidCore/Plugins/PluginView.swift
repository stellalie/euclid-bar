import Foundation

/// A screen a script opens in the panel by printing a header line, then its content:
///
///     {"view":"grid","title":"Emoji","placeholder":"Search emoji…","columns":8}
///     {"title":"grinning face","icon":"😀","paste":"😀"}
///     …
///
///     {"view":"detail","title":"Weather","code":true}
///     any text, to the end of the output
///
/// `list` and `grid` show the item lines after the header (typing filters them);
/// `detail` shows the rest of the output as text to read.
///
/// `"reload":"./list.sh"` makes it live: Euclid runs that command again (it prints the same kind of
/// view) after a `run` in the view that opened no new view, when you come back to it with `esc`,
/// and every `refresh_seconds` while it's on screen. The script keeps no state: it reads it again.
/// `"search":"./find.sh"` hands what you type to the script instead (`$1`), for searches only it
/// can do (an API); the view then shows exactly the rows it prints.
public struct PluginView: Equatable, Sendable {
    public enum Layout: String, Equatable, Sendable, CaseIterable {
        case list, grid, detail
    }

    public var layout: Layout
    public var title: String
    /// The search box's placeholder.
    public var placeholder: String?
    /// Tiles per row in a grid: 3–10, default 6.
    public var columns: Int
    public var items: [PluginItem]
    /// A detail's text.
    public var text: String
    /// Show a detail's text monospaced (command output).
    public var code: Bool
    /// A command that prints this view again with fresh content (run in the plugin's folder).
    public var reload: String?
    /// Run `reload` this often while the view is on screen: 1–3600 s; nil = only after a change.
    public var refreshSeconds: Int?
    /// A command that gets what you type as `$1` and prints the rows for it (the script searches,
    /// e.g. an API); without it, typing filters the rows the view already has.
    public var search: String?

    public static let defaultColumns = 6

    public init(layout: Layout, title: String = "", placeholder: String? = nil, columns: Int = defaultColumns,
                items: [PluginItem] = [], text: String = "", code: Bool = false, reload: String? = nil,
                refreshSeconds: Int? = nil, search: String? = nil) {
        self.layout = layout
        self.title = title
        self.placeholder = placeholder
        self.columns = min(max(columns, 3), 10)
        self.items = items
        self.text = text
        self.code = code
        let reload = reload?.trimmingCharacters(in: .whitespaces)
        self.reload = reload?.isEmpty == false ? reload : nil
        let search = search?.trimmingCharacters(in: .whitespaces)
        self.search = search?.isEmpty == false && layout != .detail ? search : nil
        self.refreshSeconds = self.reload == nil && self.search == nil ? nil : refreshSeconds.map { min(max($0, 1), 3600) }
    }
}

/// What an item's `run`, a `[[key]]` or a badge `click` printed: effects, and maybe a view.
public struct PluginResult: Equatable, Sendable {
    public var effects: [PluginEffect]
    public var view: PluginView?
    /// Item lines after a list/grid header that couldn't be read.
    public var problems: [String]

    public init(effects: [PluginEffect] = [], view: PluginView? = nil, problems: [String] = []) {
        self.effects = effects
        self.view = view
        self.problems = problems
    }

    /// Effect lines up to a `{"view":…}` header; after it, the view's content.
    /// `rows`: output with no header is the rows of a list (what a view's `search` prints).
    public static func parse(_ data: Data, rows: Bool = false) -> PluginResult {
        let text = String(decoding: data.prefix(PluginRunner.maxOutput), as: UTF8.self)
        var offset = text.startIndex
        while offset < text.endIndex {
            let end = text[offset...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[offset..<end].trimmingCharacters(in: .whitespaces)
            let next = end < text.endIndex ? text.index(after: end) : end
            if line.hasPrefix("{"), line.contains("\"view\""),
               let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let name = json["view"] as? String {
                let effects = PluginEffect.parse(Data(text[..<offset].utf8))
                guard let layout = PluginView.Layout(rawValue: name.lowercased()) else {
                    return PluginResult(effects: effects + [PluginEffect(notice: "⚠︎ unknown view “\(name)” (list, grid or detail)")])
                }
                var view = PluginView(layout: layout, title: json["title"] as? String ?? "",
                                      placeholder: json["placeholder"] as? String,
                                      columns: (json["columns"] as? Int) ?? PluginView.defaultColumns,
                                      code: json["code"] as? Bool ?? false, reload: json["reload"] as? String,
                                      refreshSeconds: (json["refresh_seconds"] as? NSNumber)?.intValue,
                                      search: json["search"] as? String)
                let rest = String(text[next...])
                var problems: [String] = []
                if layout == .detail {
                    let body = rest.trimmingCharacters(in: .newlines)
                    view.text = [json["text"] as? String, body.isEmpty ? nil : body].compactMap { $0 }.joined(separator: "\n")
                } else {
                    (view.items, problems) = PluginOutput.parse(Data(rest.utf8))
                }
                return PluginResult(effects: effects, view: view, problems: problems)
            }
            offset = next
        }
        if rows {
            let (items, problems) = PluginOutput.parse(data)
            return PluginResult(view: PluginView(layout: .list, items: items), problems: problems)
        }
        return PluginResult(effects: PluginEffect.parse(data))
    }
}

/// `euclid-bar --pick`: the lines piped in, as items. A line that is a JSON item
/// (`{"title":…,"icon":…}`) shows as one; any other line is its own title.
public enum PickInput {
    public static let maxLines = 50_000

    public static func parse(_ text: String) -> [(line: String, item: PluginItem)] {
        var out: [(String, PluginItem)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("{"), let item = try? JSONDecoder().decode(PluginItem.self, from: Data(trimmed.utf8)),
               !item.title.isEmpty {
                out.append((line, item))
            } else {
                out.append((line, PluginItem(title: trimmed)))
            }
            if out.count == maxLines { break }
        }
        return out
    }
}
