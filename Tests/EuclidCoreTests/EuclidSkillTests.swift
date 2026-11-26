import Foundation
import Testing
@testable import EuclidCore

@Suite struct EuclidSkillTests {
    func withConfig(_ toml: String?, plugin: String? = nil, _ body: (EuclidPaths) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let toml { try toml.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8) }
        if let plugin {
            let folder = dir.appendingPathComponent("plugins/gitlab")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try plugin.write(to: folder.appendingPathComponent("plugin.toml"), atomically: true, encoding: .utf8)
        }
        try body(EuclidPaths(environment: ["EUCLID_CONFIG_DIR": dir.path, "EUCLID_DATA_DIR": dir.appendingPathComponent("data").path]))
    }

    func rpc(_ s: MCPServer, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let reply = try #require(s.handle(String(decoding: request, as: UTF8.self)))
        return try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    func server(_ paths: EuclidPaths) -> MCPServer {
        MCPServer(tools: EuclidSkill.tools(paths: paths), prompts: EuclidSkill.prompts,
                  instructions: EuclidSkill.instructions(paths: paths, cli: "euclid-bar"), name: "euclid", version: "1.0")
    }

    func text(_ s: MCPServer, _ tool: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let result = try #require(try rpc(s, "tools/call", ["name": tool, "arguments": args])["result"] as? [String: Any])
        return (try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String), result["isError"] as? Bool ?? false)
    }

    @Test func connectingTeachesTheAgentWhereEverythingIs() throws {
        try withConfig("") { paths in
            let result = try #require(try rpc(server(paths), "initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any])
            let instructions = try #require(result["instructions"] as? String)
            #expect(instructions.contains("\(paths.configDirectory.path)/AGENTS.md"))
            #expect(instructions.contains("euclid_config") && instructions.contains("euclid_guide"))
            #expect(instructions.contains("Keychain")) // the rules come along
            #expect((result["capabilities"] as? [String: Any])?["prompts"] != nil)
        }
        // No prompts: no prompts capability, and no instructions unless given.
        let plain = try #require(try rpc(MCPServer(tools: [], name: "x", version: "1"), "initialize")["result"] as? [String: Any])
        #expect(plain["instructions"] == nil)
        #expect((plain["capabilities"] as? [String: Any])?["prompts"] == nil)
    }

    @Test func guidesAreTheAgentsMdFiles() throws {
        try withConfig("") { paths in
            let settings = try text(server(paths), "euclid_guide", ["topic": "settings"])
            #expect(settings.text.hasPrefix("# Euclid settings"))
            #expect(SettingsGuide.guide.contains(settings.text))
            #expect(PluginGuide.guide.contains(try text(server(paths), "euclid_guide", ["topic": "plugins"]).text))
            #expect(try text(server(paths), "euclid_guide", ["topic": "nope"]).isError)
        }
    }

    @Test func configReportShowsFileProblemsAndPlugins() throws {
        let toml = "[appearance]\ntheme = \"dracula\"\nwobble = 1\n"
        try withConfig(toml, plugin: "name = \"GitLab\"\n[source]\nrun = \"./items.sh\"\n") { paths in
            let report = try text(server(paths), "euclid_config").text
            #expect(report.contains("config: \(paths.configFile.path)"))
            #expect(report.contains("plugin: gitlab (GitLab) [source]"))
            #expect(report.contains("problems:\n- warning:") && report.contains("wobble"))
            #expect(report.hasSuffix("```toml\n[appearance]\ntheme = \"dracula\"\nwobble = 1\n```"))
        }
        try withConfig("[appearance]\ntheme = \"dracula\"\n") { paths in
            let report = try text(server(paths), "euclid_config").text
            #expect(report.contains("plugins: none installed\nproblems: none"))
        }
        try withConfig("[[broken") { paths in
            let report = try text(server(paths), "euclid_config").text
            #expect(report.contains("problems:\n- error: config.toml:"))
        }
        try withConfig(nil) { paths in
            let report = try text(server(paths), "euclid_config").text
            #expect(report.hasPrefix("No config file at"))
        }
    }

    @Test func promptsBecomeSlashCommands() throws {
        try withConfig("") { paths in
            let s = server(paths)
            let list = try #require((try rpc(s, "prompts/list")["result"] as? [String: Any])?["prompts"] as? [[String: Any]])
            #expect(list.compactMap { $0["name"] as? String } == ["settings", "plugin"])
            func message(_ name: String, _ args: [String: Any]) throws -> String {
                let result = try #require(try rpc(s, "prompts/get", ["name": name, "arguments": args])["result"] as? [String: Any])
                let first = try #require((result["messages"] as? [[String: Any]])?.first)
                #expect(first["role"] as? String == "user")
                return try #require((first["content"] as? [String: Any])?["text"] as? String)
            }
            #expect(try message("settings", ["request": "open with ⌥Space"]).hasPrefix("Change my Euclid settings: open with ⌥Space"))
            #expect(try message("settings", [:]).hasPrefix("Help me set up Euclid."))
            #expect(try message("plugin", ["what": "my GitLab MRs"]).hasPrefix("Make me a Euclid plugin: my GitLab MRs"))
            #expect((try rpc(s, "prompts/get", ["name": "plugin"])["error"] as? [String: Any])?["message"] as? String == "Missing argument: what")
            #expect(try rpc(s, "prompts/get", ["name": "nope"])["error"] != nil)
        }
    }
}
