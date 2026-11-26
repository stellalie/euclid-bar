import Foundation

/// `euclid-bar --tool [<name> key=value…]`: the tools agents get over MCP, from a shell or a script.
/// No name lists them. Values are strings, or numbers where the tool's schema says integer.
public enum ToolCommand {
    public static func run(_ args: [String], tools: [MCPServer.Tool]) -> (output: String, status: Int32) {
        guard let name = args.first, !name.hasPrefix("-") else { return (list(tools), args.isEmpty ? 0 : 64) }
        guard let tool = tools.first(where: { $0.name == name }) else {
            return ("error: no tool named '\(name)'\n\n" + list(tools), 64)
        }
        let properties = tool.inputSchema["properties"] as? [String: [String: Any]] ?? [:]
        var input: [String: Any] = [:]
        for pair in args.dropFirst() {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else {
                return ("error: arguments are key=value, got '\(pair)'\n\n" + usage(tool), 64)
            }
            let key = String(pair[..<eq]), value = String(pair[pair.index(after: eq)...])
            guard let type = properties[key]?["type"] as? String else {
                return ("error: \(name) has no argument '\(key)'\n\n" + usage(tool), 64)
            }
            if type == "integer" {
                guard let n = Int(value) else { return ("error: \(key) must be a whole number, got '\(value)'", 64) }
                input[key] = n
            } else {
                input[key] = value
            }
        }
        let missing = (tool.inputSchema["required"] as? [String] ?? []).filter { input[$0] == nil }
        guard missing.isEmpty else { return ("error: \(name) needs \(missing.map { "\($0)=…" }.joined(separator: " "))\n\n" + usage(tool), 64) }
        do {
            return (try tool.run(input), 0)
        } catch {
            return ("error: \(error)", 1)
        }
    }

    static func list(_ tools: [MCPServer.Tool]) -> String {
        let width = tools.map(\.name.count).max() ?? 0
        let rows = tools.map { $0.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + firstSentence($0.description) }
        return (["usage: euclid-bar --tool <name> [key=value…]", ""] + rows).joined(separator: "\n")
    }

    static func usage(_ tool: MCPServer.Tool) -> String {
        let properties = tool.inputSchema["properties"] as? [String: [String: Any]] ?? [:]
        let required = Set(tool.inputSchema["required"] as? [String] ?? [])
        let args = properties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }
            .map { required.contains($0) ? "\($0)=…" : "[\($0)=…]" }
        return (["usage: euclid-bar --tool \(([tool.name] + args).joined(separator: " "))", firstSentence(tool.description)]
                + properties.keys.sorted().map { "  \($0): \(properties[$0]?["description"] as? String ?? "")" }).joined(separator: "\n")
    }

    static func firstSentence(_ s: String) -> String {
        guard let end = s.range(of: ". ") else { return s }
        return String(s[..<end.lowerBound]) + "."
    }
}
