import Foundation

/// A minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0):
/// enough for agents like Claude Code and Codex to list and call tools.
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

    public struct ToolError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Protocol versions this server speaks, newest first. A client asking for another gets the newest,
    /// as the spec says, and decides itself whether it can go on.
    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]
    let tools: [Tool]
    let name: String
    let version: String

    public init(tools: [Tool], name: String, version: String) {
        self.tools = tools
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
            return reply(id, [
                "protocolVersion": asked.flatMap { Self.supportedProtocols.contains($0) ? $0 : nil } ?? Self.supportedProtocols[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": version],
            ])
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
