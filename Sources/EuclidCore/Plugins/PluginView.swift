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

    public static let defaultColumns = 6

    public init(layout: Layout, title: String = "", placeholder: String? = nil, columns: Int = defaultColumns,
                items: [PluginItem] = [], text: String = "", code: Bool = false) {
        self.layout = layout
        self.title = title
        self.placeholder = placeholder
        self.columns = min(max(columns, 3), 10)
        self.items = items
        self.text = text
        self.code = code
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
    public static func parse(_ data: Data) -> PluginResult {
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
                                      code: json["code"] as? Bool ?? false)
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
