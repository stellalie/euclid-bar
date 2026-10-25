import Foundation

/// What Euclid shares with your coding agents over MCP (`euclid-bar --mcp`): your clipboard
/// history, the pages and notes it indexed, and browser history. Read-only, local, and only
/// the sources listed in `[agents] share`.
public enum AgentTools {
    public enum Source: String, CaseIterable, Sendable { case clipboard, pages, notes, history }

    /// Where the data comes from. Closures, so tests can hand in fixtures.
    public struct Store {
        public var clips: () throws -> [Clip]
        public var search: (_ query: String, _ limit: Int) throws -> [ContentHit]
        public var body: (_ ref: String) -> String?
        public var history: () -> [HistoryEntry]
        /// Why some browser history couldn't be read (e.g. Safari without Full Disk Access), told to the agent.
        public var historyNote: () -> String? = { nil }

        public init(clips: @escaping () throws -> [Clip], search: @escaping (String, Int) throws -> [ContentHit],
                    body: @escaping (String) -> String?, history: @escaping () -> [HistoryEntry]) {
            self.clips = clips
            self.search = search
            self.body = body
            self.history = history
        }
    }

    /// Longest clip or page text returned, so one huge paste can't flood an agent's context.
    static let maxClip = 4_000
    static let maxBody = 40_000

    public static func make(_ data: Store, share: Set<Source>, now: @escaping () -> Date = Date.init) -> [MCPServer.Tool] {
        var tools: [MCPServer.Tool] = []
        let query = ["type": "string", "description": "Words to look for (all must appear, any order)."]
        func limit(_ n: Int) -> [String: Any] { ["type": "integer", "description": "Most results to return (default \(n))."] }

        if share.contains(.clipboard) {
            let textClips = { try data.clips().filter { $0.kind == .text }.sorted { $0.lastUsedAt > $1.lastUsedAt } }
            tools.append(.init(
                name: "search_clipboard",
                description: "Search the user's clipboard history (text they copied: commands, errors, snippets, URLs), newest first.",
                inputSchema: schema(["query": query, "limit": limit(10)], required: ["query"])) { args in
                let words = try terms(args)
                let hits = try textClips().filter { c in words.allSatisfy(c.content.lowercased().contains) }
                return clipText(Array(hits.prefix(count(args, 10))), now: now())
            })
            tools.append(.init(
                name: "recent_clipboard",
                description: "The most recent entries in the user's clipboard history, newest first.",
                inputSchema: schema(["limit": limit(10)], required: [])) { args in
                clipText(Array(try textClips().prefix(count(args, 10))), now: now())
            })
        }

        let kinds = Set([share.contains(.pages) ? ContentHit.Kind.page : nil, share.contains(.notes) ? .note : nil].compactMap { $0 })
        if !kinds.isEmpty {
            let what = kinds.count == 2 ? "web pages the user visited and their Obsidian notes" : kinds.contains(.page) ? "web pages the user visited" : "the user's Obsidian notes"
            tools.append(.init(
                name: "search_pages_and_notes",
                description: "Full-text search of \(what), indexed on their Mac. Returns titles, refs (URL or note path) and matching snippets; read one with read_page_or_note.",
                inputSchema: schema(["query": query, "limit": limit(8)], required: ["query"])) { args in
                let words = try terms(args)
                let hits = try data.search(words.joined(separator: " "), 50).filter { kinds.contains($0.kind) }.prefix(count(args, 8))
                guard !hits.isEmpty else { return "No matches." }
                return hits.map { "\($0.title)\n\($0.ref)\n\($0.snippet)" }.joined(separator: "\n\n")
            })
            tools.append(.init(
                name: "read_page_or_note",
                description: "The full indexed text of a page or note, by the ref search_pages_and_notes returned.",
                inputSchema: schema(["ref": ["type": "string", "description": "A URL or note path from search_pages_and_notes."]], required: ["ref"])) { args in
                guard let ref = args["ref"] as? String, !ref.isEmpty else { throw MCPServer.ToolError("ref is required") }
                let isNote = ref.hasPrefix("/")
                guard kinds.contains(isNote ? .note : .page), let body = data.body(ref) else { return "Not in the index: \(ref)" }
                return body.count > maxBody ? String(body.prefix(maxBody)) + "\n…(cut)" : body
            })
        }

        if share.contains(.history) {
            tools.append(.init(
                name: "search_browser_history",
                description: "Search the user's browser history (titles and URLs, every browser), most recent first.",
                inputSchema: schema(["query": query, "limit": limit(20)], required: ["query"])) { args in
                let words = try terms(args)
                let hits = data.history().filter { e in words.allSatisfy { "\(e.title) \(e.url)".lowercased().contains($0) } }
                    .sorted { $0.lastVisit > $1.lastVisit }.prefix(count(args, 20))
                let note = data.historyNote().map { "\n\nNote: \($0)" } ?? ""
                guard !hits.isEmpty else { return "No matches." + note }
                return hits.map { "\($0.title.isEmpty ? $0.url : $0.title) — \($0.url) (\($0.browser), \(RelativeAge.short($0.lastVisit, now: now())))" }
                    .joined(separator: "\n") + note
            })
        }
        return tools
    }

    static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    static func terms(_ args: [String: Any]) throws -> [String] {
        let words = (args["query"] as? String ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { throw MCPServer.ToolError("query is required") }
        return words
    }

    static func count(_ args: [String: Any], _ fallback: Int) -> Int {
        min(max((args["limit"] as? Int) ?? fallback, 1), 100)
    }

    static func clipText(_ clips: [Clip], now: Date) -> String {
        guard !clips.isEmpty else { return "No matches." }
        return clips.map { c in
            let from = c.sourceName.map { " from \($0)" } ?? ""
            let text = c.content.count > maxClip ? String(c.content.prefix(maxClip)) + "\n…(cut)" : c.content
            return "— copied \(RelativeAge.short(c.lastUsedAt, now: now))\(from)\n\(text)"
        }.joined(separator: "\n\n")
    }
}
