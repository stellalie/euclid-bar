import Foundation
import EuclidCore

/// `euclid-bar --mcp`: an MCP server on stdin/stdout so Claude Code, Codex and other agents can
/// search what Euclid indexed, and learn the user's Euclid setup (`EuclidSkill`). Runs as its own process next to the app; reads the same files.
@MainActor
enum AgentServer {
    static func run() -> Int32 {
        let paths = EuclidPaths()
        let cli = Bundle.main.executablePath ?? "/Applications/Euclid.app/Contents/MacOS/euclid-bar"
        MCPServer(tools: tools(paths: paths), prompts: EuclidSkill.prompts, instructions: EuclidSkill.instructions(paths: paths, cli: cli),
                  name: "euclid", version: Updater.version).serve()
        return 0
    }

    /// `euclid-bar --tool [<name> key=value…]`: the same tools, from a shell.
    static func tool(_ args: [String]) -> Int32 {
        let (output, status) = ToolCommand.run(args, tools: tools(paths: EuclidPaths()))
        if status == 0 { print(output) } else { FileHandle.standardError.write(Data((output + "\n").utf8)) }
        return status
    }

    /// Everything an agent can call: the Euclid skill and the sources config.toml shares.
    static func tools(paths: EuclidPaths) -> [MCPServer.Tool] {
        // Read-only: never write a default config.toml from here; the app does that on first launch.
        let config = FileManager.default.fileExists(atPath: paths.configFile.path)
            ? (try? ConfigLoader.loadOrCreate(at: paths.configFile))?.config ?? EuclidConfig()
            : EuclidConfig()
        let clips = try? ClipStore(path: paths.historyDatabase.path)
        let content = try? ContentIndex(path: paths.contentDatabase.path)
        var history: [HistoryEntry]?
        var unreadable: [String] = []
        var store = AgentTools.Store(
            clips: { try clips?.loadRecent(limit: config.clipboardLimit) ?? [] },
            search: { query, limit in try content?.search(query, limit: limit) ?? [] },
            body: { content?.body(ref: $0) },
            history: {
                // Copying every browser's history file is slow-ish: once per session is plenty.
                if let history { return history }
                let browsers = config.historyBrowsers
                let sources = config.historyEnabled ? BrowserHistory.discoverSources().filter { browsers?.contains($0.key) ?? true } : []
                let (entries, errors) = BrowserHistory.load(sources, limit: config.historyLimit)
                let loaded = BrowserHistory.dedupe(entries)
                unreadable = errors.map(\.0.browser)
                history = loaded
                return loaded
            })
        // Launched by an agent, this process has the terminal's permissions, not Euclid's.
        store.historyNote = {
            guard !unreadable.isEmpty else { return nil }
            let safari = unreadable.contains("Safari")
                ? " Safari history needs Full Disk Access for the app that runs your agent (your terminal or editor)." : ""
            return "couldn't read \(unreadable.joined(separator: ", ")) history.\(safari)"
        }
        return EuclidSkill.tools(paths: paths) + AgentTools.make(store, share: config.agentShare)
    }
}
