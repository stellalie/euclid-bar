import Foundation

/// A minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0):
/// enough for agents like Claude Code and Codex to list and call tools and prompts, plus
/// `instructions` the client adds to the agent's context as soon as it connects.
public final class MCPServer {
    public struct Tool {
        public let name: String
        public let description: String
        /// JSON Schema for the arguments.
        public let inputSchema: [String: Any]
        public let run: ([String: Any]) throws -> String

        public init(name: String, description: String, inputSchema: [String: Any], run: @escaping ([String: Any]) throws -> String) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.run = run
        }
    }

    /// A prompt template: Claude Code shows each as a slash command (`/mcp__euclid__<name>`).
    public struct Prompt {
        public struct Argument {
            public let name: String
            public let description: String
            public let required: Bool
            public init(name: String, description: String, required: Bool = false) {
                self.name = name
                self.description = description
                self.required = required
            }
        }
        public let name: String
        public let description: String
        public let arguments: [Argument]
        /// The user message the prompt expands to, from its arguments.
        public let render: ([String: String]) -> String

        public init(name: String, description: String, arguments: [Argument] = [], render: @escaping ([String: String]) -> String) {
            self.name = name
            self.description = description
            self.arguments = arguments
            self.render = render
        }
    }

    public struct ToolError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Protocol versions this server speaks, newest first. A client asking for another gets the newest,
    /// as the spec says, and decides itself whether it can go on.
    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]
    let tools: [Tool]
    let prompts: [Prompt]
    let instructions: String?
    let name: String
    let version: String

    public init(tools: [Tool], prompts: [Prompt] = [], instructions: String? = nil, name: String, version: String) {
        self.tools = tools
        self.prompts = prompts
        self.instructions = instructions
        self.name = name
        self.version = version
    }

    /// Read requests from `input` until it closes, answering on `output`.
    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while case let chunk = input.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let reply = handle(line) { output.write(Data((reply + "\n").utf8)) }
            }
        }
    }

    /// One JSON-RPC message in, the reply out (nil for notifications).
    public func handle(_ line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil } // a notification, e.g. notifications/initialized
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            var capabilities: [String: Any] = ["tools": [String: Any]()]
            if !prompts.isEmpty { capabilities["prompts"] = [String: Any]() }
            var result: [String: Any] = [
                "protocolVersion": asked.flatMap { Self.supportedProtocols.contains($0) ? $0 : nil } ?? Self.supportedProtocols[0],
                "capabilities": capabilities,
                "serverInfo": ["name": name, "version": version],
            ]
            if let instructions { result["instructions"] = instructions }
            return reply(id, result)
        case "ping":
            return reply(id, [String: Any]())
        case "tools/list":
            return reply(id, ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] }])
        case "tools/call":
            guard let toolName = params["name"] as? String, let tool = tools.first(where: { $0.name == toolName }) else {
                return error(id, code: -32602, "Unknown tool: \(params["name"] ?? "")")
            }
            do {
                let text = try tool.run(params["arguments"] as? [String: Any] ?? [:])
                return reply(id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                return reply(id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        case "prompts/list":
            return reply(id, ["prompts": prompts.map { p in
                ["name": p.name, "description": p.description,
                 "arguments": p.arguments.map { ["name": $0.name, "description": $0.description, "required": $0.required] }]
            }])
        case "prompts/get":
            guard let promptName = params["name"] as? String, let prompt = prompts.first(where: { $0.name == promptName }) else {
                return error(id, code: -32602, "Unknown prompt: \(params["name"] ?? "")")
            }
            let args = (params["arguments"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            if let missing = prompt.arguments.first(where: { $0.required && (args[$0.name] ?? "").isEmpty }) {
                return error(id, code: -32602, "Missing argument: \(missing.name)")
            }
            return reply(id, ["description": prompt.description,
                              "messages": [["role": "user", "content": ["type": "text", "text": prompt.render(args)]]]])
        default:
            return error(id, code: -32601, "Method not found: \(message["method"] ?? "")")
        }
    }

    private func reply(_ id: Any, _ result: Any) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func error(_ id: Any, code: Int, _ message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }
}
