import Foundation

/// Turns snippets and quicklinks exported from Raycast or Alfred into `[[snippet]]` and
/// `[[action]]` blocks for config.toml, so switching keeps what you built up there.
///
/// Reads, one JSON file at a time:
/// - Raycast › Snippets › Export: `[{"name", "text", "keyword"}]`
/// - Raycast › Quicklinks › Export: `[{"name", "link"}]`
/// - Alfred's `.alfredsnippets` (a zip; unpack it first): one `{"alfredsnippet": {"name", "snippet", "keyword"}}` per file
public enum LauncherImport {
    public struct Quicklink: Equatable, Sendable {
        public let name: String
        /// A shell command for `run`: `open "<url>"`, with the typed text as `$EUCLID_QUERY_URL`.
        public let run: String
    }

    public struct Result: Equatable, Sendable {
        public var snippets: [Snippet] = []
        public var quicklinks: [Quicklink] = []
        /// One line per entry that couldn't be brought over, and why.
        public var skipped: [String] = []

        public init() {}
        public var isEmpty: Bool { snippets.isEmpty && quicklinks.isEmpty }
    }

    /// Everything importable in one exported file. `existing` names (already in config.toml) are skipped.
    public static func parse(_ data: Data, fileName: String, into result: inout Result, existing: Set<String> = []) {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            result.skipped.append("\(fileName): not a JSON export"); return
        }
        let entries: [[String: Any]]
        if let list = json as? [[String: Any]] { entries = list }
        else if let one = json as? [String: Any] { entries = [(one["alfredsnippet"] as? [String: Any]) ?? one] }
        else { result.skipped.append("\(fileName): not a Raycast or Alfred export"); return }

        var taken = existing.union(result.snippets.map(\.name)).union(result.quicklinks.map(\.name))
        for entry in entries {
            let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !name.isEmpty else {
                result.skipped.append("\(fileName): an entry without a name"); continue
            }
            guard !taken.contains(name) else { result.skipped.append("\(name): already in your config"); continue }
            if let link = entry["link"] as? String {
                guard let run = command(forLink: link) else {
                    result.skipped.append("\(name): only web links can be imported (\(link.prefix(40)))"); continue
                }
                result.quicklinks.append(Quicklink(name: name, run: run))
            } else if let text = (entry["text"] ?? entry["snippet"]) as? String, !text.isEmpty {
                let keyword = (entry["keyword"] as? String).flatMap { $0.isEmpty || $0.contains(" ") ? nil : $0 }
                result.snippets.append(Snippet(name: name, keyword: keyword, text: placeholders(text)))
            } else {
                result.skipped.append("\(name): neither a snippet nor a quicklink"); continue
            }
            taken.insert(name)
        }
    }

    /// Raycast and Alfred placeholders → Euclid's. `{cursor}` has no equivalent and is dropped.
    static func placeholders(_ text: String) -> String {
        guard text.contains("{") else { return text }
        var out = text
        for (pattern, template) in [
            (#"\{(datetime|date|time)(?:[ :][^}]*)?\}"#, "{$1}"),     // {date format="…"}, {date:short}
            (#"\{clipboard(?:[ :][^}]*)?\}"#, "{clipboard}"),          // {clipboard offset=1}, {clipboard:1}
            (#"\{random:UUID\}"#, "{uuid}"),
            (#"\{cursor\}"#, ""),
        ] {
            out = out.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// `open "<url>"` for an http(s) quicklink, with `{argument…}` / `{query}` as the typed text.
    static func command(forLink link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard let scheme = trimmed.split(separator: ":", maxSplits: 1).first?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let marker = "\u{1}"
        let url = trimmed.replacingOccurrences(of: #"\{(argument|query)(?: [^}]*)?\}"#, with: marker, options: [.regularExpression, .caseInsensitive])
        // Inside shell double quotes only \ " $ ` are special; escape them so the URL stays inert.
        var escaped = ""
        for c in url {
            if "\\\"$`".contains(c) { escaped.append("\\") }
            escaped.append(c)
        }
        return #"open ""# + escaped.replacingOccurrences(of: marker, with: "$EUCLID_QUERY_URL") + #"""#
    }

    /// TOML blocks to append to config.toml.
    public static func toml(_ result: Result, source: String) -> String {
        var lines = ["", "# Imported from \(source)"]
        for s in result.snippets {
            lines += ["", "[[snippet]]", "name = \(quoted(s.name))"]
            if let k = s.keyword { lines.append("keyword = \(quoted(k))") }
            lines.append("text = \(quoted(s.text))")
        }
        for q in result.quicklinks {
            lines += ["", "[[action]]", "name = \(quoted(q.name))", "run = \(quoted(q.run))"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A TOML string: multi-line when the text has line breaks, so snippets stay readable.
    static func quoted(_ s: String) -> String {
        var body = ""
        let multiline = s.contains("\n")
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": body += "\\\\"
            case "\"": body += "\\\""
            case "\n" where multiline: body += "\n"
            case "\n": body += "\\n"
            case "\t": body += "\\t"
            case "\r": body += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: body += String(format: "\\u%04X", scalar.value)
            default: body.unicodeScalars.append(scalar)
            }
        }
        return multiline ? "\"\"\"\n\(body)\"\"\"" : "\"\(body)\""
    }
}
