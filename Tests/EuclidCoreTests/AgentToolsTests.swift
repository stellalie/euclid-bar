import Foundation
import Testing
@testable import EuclidCore

@Suite struct AgentToolsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var store: AgentTools.Store {
        let now = now
        let clips = [
            Clip(id: 2, content: "kubectl logs -f deploy/search --since=1h", kind: .text, sourceName: "Ghostty",
                 createdAt: now.addingTimeInterval(-7200), lastUsedAt: now.addingTimeInterval(-7200), useCount: 1),
            Clip(id: 1, content: "/Users/me/shot.png", kind: .files, createdAt: now, lastUsedAt: now, useCount: 1),
            Clip(id: 3, content: "SELECT * FROM deploys", kind: .text, createdAt: now.addingTimeInterval(-60), lastUsedAt: now.addingTimeInterval(-60), useCount: 1),
        ]
        let hits = [
            ContentHit(kind: .page, ref: "https://k8s.io/docs/logs", title: "Logging", snippet: "…kubectl logs…"),
            ContentHit(kind: .note, ref: "/Users/me/Notes/Deploy.md", title: "Deploy", snippet: "…logs live in…"),
        ]
        return AgentTools.Store(
            clips: { clips },
            search: { _, _ in hits },
            body: { ["https://k8s.io/docs/logs": "Full page", "/Users/me/Notes/Deploy.md": "Full note"][$0] },
            history: { [HistoryEntry(url: "https://grafana.example.com/d/search", title: "Search latency", browser: "Dia",
                                     lastVisit: now.addingTimeInterval(-300), visitCount: 3)] })
    }

    func server(_ share: Set<AgentTools.Source> = Set(AgentTools.Source.allCases)) -> MCPServer {
        MCPServer(tools: AgentTools.make(store, share: share, now: { self.now }), name: "euclid", version: "1.0")
    }

    func call(_ s: MCPServer, _ tool: String, _ args: [String: Any]) throws -> (text: String, isError: Bool) {
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                                  "params": ["name": tool, "arguments": args]])
        let reply = try #require(s.handle(String(decoding: request, as: UTF8.self)))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let result = try #require(obj["result"] as? [String: Any])
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (text, result["isError"] as? Bool ?? false)
    }

    @Test func handshakeAndToolList() throws {
        let s = server()
        let initReply = try #require(s.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-code"}}}"#))
        #expect(initReply.contains(#""protocolVersion":"2025-03-26""#))
        #expect(initReply.contains(#""serverInfo":{"name":"euclid","version":"1.0"}"#))
        #expect(s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(s.handle(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#) == #"{"id":2,"jsonrpc":"2.0","result":{}}"#)
        let list = try #require(s.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        for name in ["search_clipboard", "recent_clipboard", "search_pages_and_notes", "read_page_or_note", "search_browser_history"] {
            #expect(list.contains(#""name":"\#(name)""#), "\(name)")
        }
        #expect(s.handle(#"{"jsonrpc":"2.0","id":4,"method":"nope"}"#)?.contains("-32601") == true)
        #expect(s.handle("{not json")?.contains("-32700") == true)
    }

    @Test func clipboardSearchIsTextOnlyAndNewestFirst() throws {
        let hit = try call(server(), "search_clipboard", ["query": "LOGS deploy"])
        #expect(hit.text == "— copied 2h ago from Ghostty\nkubectl logs -f deploy/search --since=1h")
        let recent = try call(server(), "recent_clipboard", ["limit": 1])
        #expect(recent.text == "— copied 1m ago\nSELECT * FROM deploys")
        #expect(try call(server(), "search_clipboard", ["query": "  "]).isError)
    }

    @Test func pagesNotesAndHistory() throws {
        let both = try call(server(), "search_pages_and_notes", ["query": "logs"]).text
        #expect(both == "Logging\nhttps://k8s.io/docs/logs\n…kubectl logs…\n\nDeploy\n/Users/me/Notes/Deploy.md\n…logs live in…")
        #expect(try call(server(), "read_page_or_note", ["ref": "/Users/me/Notes/Deploy.md"]).text == "Full note")
        #expect(try call(server(), "search_browser_history", ["query": "latency"]).text
                == "Search latency — https://grafana.example.com/d/search (Dia, 5m ago)")
    }

    @Test func onlySharedSourcesAreExposed() throws {
        let s = server([.notes])
        let list = try #require(s.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        #expect(!list.contains("clipboard") && !list.contains("search_browser_history"))
        #expect(try call(s, "search_pages_and_notes", ["query": "logs"]).text == "Deploy\n/Users/me/Notes/Deploy.md\n…logs live in…")
        #expect(try call(s, "read_page_or_note", ["ref": "https://k8s.io/docs/logs"]).text == "Not in the index: https://k8s.io/docs/logs")
        #expect(s.handle(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"search_clipboard","arguments":{"query":"x"}}}"#)?.contains("Unknown tool") == true)
    }

    @Test func servesOverPipes() throws {
        let input = Pipe(), output = Pipe()
        // Split mid-message: the server must buffer until the newline.
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"me"#.utf8))
        input.fileHandleForWriting.write(Data("thod\":\"ping\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n".utf8))
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8 + [0x0A]))
        try input.fileHandleForWriting.close()
        server().serve(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let replies = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(replies == #"{"id":1,"jsonrpc":"2.0","result":{}}"# + "\n" + #"{"id":2,"jsonrpc":"2.0","result":{}}"# + "\n")
    }

    @Test func configShare() throws {
        let c = try ConfigLoader.parse("[agents]\nshare = [\"notes\", \"Pages\", \"email\"]")
        #expect(c.config.agentShare == [.notes, .pages])
        #expect(c.issues.map(\.message) == ["agents.share: unknown source 'email' (use clipboard, pages, notes, history)"])
        #expect(try ConfigLoader.parse("").config.agentShare == Set(AgentTools.Source.allCases))
    }
}
