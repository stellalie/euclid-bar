import Foundation

/// What a hook or a `[[key]]` script asks Euclid to do, one JSON object per line:
///
///     {"notice":"Cleaned 2 tracking links"}
///     {"copy":"https://example.com/page"}
///
/// Lines that aren't JSON objects are ignored, so a script can also log.
public struct PluginEffect: Equatable, Sendable, Decodable {
    /// Shown in the panel's footer (now, or the next time it opens).
    public var notice: String?
    /// Put this text on the clipboard.
    public var copy: String?
    /// Open this URL or file path.
    public var open: String?
    /// `open` hooks only: start the search with this text, unless you already typed.
    public var query: String?

    public init(notice: String? = nil, copy: String? = nil, open: String? = nil, query: String? = nil) {
        self.notice = notice
        self.copy = copy
        self.open = open
        self.query = query
    }

    public static func parse(_ data: Data) -> [PluginEffect] {
        String(decoding: data.prefix(256 * 1024), as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), let e = try? JSONDecoder().decode(PluginEffect.self, from: Data(t.utf8)),
                  e != PluginEffect() else { return nil }
            return e
        }
    }
}

/// The selected result, as `[[key]]` and `choose` hook scripts see it.
public struct ModItem: Equatable, Sendable {
    /// app, project, file, clip, page, note, history, pr, issue, snippet, action, answer, task, command or plugin.
    public let kind: String
    public let title: String
    public var subtitle = ""
    public var url: String?
    public var path: String?
    public var text: String?
    /// For a plugin's item: the plugin's id.
    public var pluginID: String?

    public init(kind: String, title: String, subtitle: String = "", url: String? = nil, path: String? = nil,
                text: String? = nil, pluginID: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.path = path
        self.text = text
        self.pluginID = pluginID
    }

    /// `$1`: the thing itself — its URL, path or text, else its title.
    public var value: String { url ?? path ?? text ?? title }

    public var environment: [String: String] {
        var env = ["EUCLID_ITEM_KIND": kind, "EUCLID_ITEM_TITLE": title, "EUCLID_ITEM_SUBTITLE": subtitle]
        if let url { env["EUCLID_ITEM_URL"] = url }
        if let path { env["EUCLID_ITEM_PATH"] = path }
        if let text { env["EUCLID_ITEM_TEXT"] = String(text.prefix(100_000)) }
        if let pluginID { env["EUCLID_ITEM_PLUGIN"] = pluginID }
        return env
    }
}
