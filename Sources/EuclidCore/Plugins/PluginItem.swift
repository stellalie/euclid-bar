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

    public init(title: String, subtitle: String? = nil, open: String? = nil, copy: String? = nil, paste: String? = nil,
                run: String? = nil, icon: String? = nil, label: String? = nil, preview: String? = nil,
                id: String? = nil, suggest: Bool? = nil) {
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
    }

    public var key: String { id ?? open ?? title }

    public func searchItem(id: Int) -> SearchItem {
        SearchItem(id: id, title: title, subtitle: subtitle ?? "", searchText: "\(title) \(subtitle ?? "")")
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
                    problems.append("line \(n + 1): a field has the wrong type (all are strings, suggest is true/false)"); continue
                }
                items.append(item)
                if items.count == maxItems { problems.append("stopped at \(maxItems) items"); break }
            }
        }
        items.removeAll { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        return (Array(items.prefix(maxItems)), problems)
    }
}
