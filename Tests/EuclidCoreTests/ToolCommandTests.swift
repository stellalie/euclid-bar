import Foundation
import Testing
@testable import EuclidCore

/// `euclid-bar --tool`: the agent tools from a shell.
@Suite struct ToolCommandTests {
    let tools = [
        MCPServer.Tool(name: "search_clipboard", description: "Search the clipboard. Newest first.",
                       inputSchema: AgentTools.schema(["query": ["type": "string", "description": "Words to look for."],
                                                       "limit": ["type": "integer", "description": "Most results."]],
                                                      required: ["query"])) { args in
            "query=\(args["query"] as? String ?? "-") limit=\(args["limit"].map { "\($0)" } ?? "-") \(type(of: args["limit"] ?? ""))"
        },
        MCPServer.Tool(name: "broken", description: "Always fails.", inputSchema: AgentTools.schema([:], required: [])) { _ in
            throw MCPServer.ToolError("index is missing")
        },
    ]

    @Test func runsAToolWithTypedArguments() {
        let r = ToolCommand.run(["search_clipboard", "query=docker ps", "limit=5"], tools: tools)
        #expect(r.status == 0)
        #expect(r.output == "query=docker ps limit=5 Int") // the schema's integer arrives as a number
        #expect(ToolCommand.run(["search_clipboard", "query=a=b"], tools: tools).output.hasPrefix("query=a=b limit=-"))
    }

    @Test func listsAndExplains() {
        let list = ToolCommand.run([], tools: tools)
        #expect(list.status == 0)
        #expect(list.output.contains("search_clipboard  Search the clipboard."))
        #expect(list.output.contains("broken            Always fails."))

        let missing = ToolCommand.run(["search_clipboard"], tools: tools)
        #expect(missing.status == 64)
        #expect(missing.output.hasPrefix("error: search_clipboard needs query=…"))
        #expect(missing.output.contains("usage: euclid-bar --tool search_clipboard query=… [limit=…]"))

        #expect(ToolCommand.run(["nope"], tools: tools).output.hasPrefix("error: no tool named 'nope'"))
        #expect(ToolCommand.run(["search_clipboard", "query=x", "color=red"], tools: tools).output.hasPrefix("error: search_clipboard has no argument 'color'"))
        #expect(ToolCommand.run(["search_clipboard", "query=x", "limit=lots"], tools: tools).output == "error: limit must be a whole number, got 'lots'")
        #expect(ToolCommand.run(["search_clipboard", "docker"], tools: tools).output.hasPrefix("error: arguments are key=value"))
    }

    @Test func helpShowsUsageAndSucceeds() {
        let help = ToolCommand.run(["search_clipboard", "--help"], tools: tools)
        #expect(help.status == 0)
        #expect(help.output.hasPrefix("usage: euclid-bar --tool search_clipboard query=… [limit=…]"))
        #expect(help.output.contains("  query: Words to look for."))
        #expect(ToolCommand.run(["search_clipboard", "query=x", "-h"], tools: tools).status == 0)
        #expect(ToolCommand.run(["--help"], tools: tools).status == 0)
        #expect(ToolCommand.run(["--bogus"], tools: tools).status == 64)
    }

    @Test func aFailingToolSaysWhy() {
        let r = ToolCommand.run(["broken"], tools: tools)
        #expect(r.status == 1)
        #expect(r.output == "error: index is missing")
    }
}
