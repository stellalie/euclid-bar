import Foundation

/// Teaches a coding agent the user's Euclid setup the moment it connects to `euclid-bar --mcp`:
/// `instructions` (added to the agent's context by Claude Code), two tools that serve the same
/// guides Euclid keeps as `AGENTS.md` plus the user's live config, and two prompts that Claude Code
/// shows as `/mcp__euclid__settings` and `/mcp__euclid__plugin`. Nothing here is a second copy of
/// the docs: the guides are `SettingsGuide.guide` and `PluginGuide.guide`.
public enum EuclidSkill {
    /// `cli` is the `euclid-bar` binary the agent can run (`--try-plugin`).
    public static func instructions(paths: EuclidPaths, cli: String) -> String {
        let dir = ProjectScanner.abbreviate(paths.configDirectory.path)
        return """
            Euclid is the user's search bar for their Mac (menu bar app, opens with a hotkey). Everything it does is \
            set in plain files in \(dir): config.toml, plugins/<id>/ (plugin.toml and its scripts) and bin/ \
            (helper scripts on PATH). Euclid reloads on save.

            When the user asks to change Euclid (hotkey, theme, apps or folders to search, snippets, web searches, \
            actions) or to add something to the bar (items from a script or an API, an answer, a status badge), \
            edit those files yourself:
            1. Call euclid_config: their config.toml, installed plugins and any problems.
            2. Call euclid_guide with topic "settings" (every setting) or "plugins" (the plugin format) before \
            writing anything. The same guides are \(dir)/AGENTS.md and \(dir)/plugins/AGENTS.md.
            3. After editing, call euclid_config again and fix every problem it lists. For a plugin, also run \
            `\(cli) --try-plugin <id> [query]`.
            4. Tell the user what changed in one or two sentences.

            The user's rules for Euclid's files:
            \(SettingsGuide.rules)

            The other tools here search what Euclid indexed for the user (clipboard, notes, browser history), \
            only the sources they share in [agents] share.
            """
    }

    /// Longest config.toml returned.
    static let maxConfig = 40_000

    public static func tools(paths: EuclidPaths, readFile: @escaping (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) -> [MCPServer.Tool] {
        [
            .init(
                name: "euclid_guide",
                description: "How to set up Euclid, the user's Mac search bar: \"settings\" is every config.toml setting with comments; \"plugins\" is the plugin format (scripts that add items, answers, badges and keys). Read it before editing Euclid's files.",
                inputSchema: AgentTools.schema(["topic": ["type": "string", "enum": ["settings", "plugins"],
                                                          "description": "settings or plugins"]], required: ["topic"])) { args in
                switch args["topic"] as? String {
                case "settings": return withoutMarker(SettingsGuide.guide)
                case "plugins": return withoutMarker(PluginGuide.guide)
                default: throw MCPServer.ToolError("topic must be \"settings\" or \"plugins\"")
                }
            },
            .init(
                name: "euclid_config",
                description: "The user's Euclid setup as Euclid reads it now: config.toml (path and full text), included files, installed plugins and their folders, and every problem Euclid finds. Call it before changing Euclid, and again after to check your edit.",
                inputSchema: AgentTools.schema([:], required: [])) { _ in
                report(paths: paths, readFile: readFile)
            },
        ]
    }

    public static var prompts: [MCPServer.Prompt] { [
        .init(name: "settings", description: "Change Euclid's settings in plain words",
              arguments: [.init(name: "request", description: "What you'd like Euclid to do, e.g. \"open with ⌥Space\" or \"a Dracula theme\"")]) { args in
            let ask = args["request"].flatMap { $0.isEmpty ? nil : $0 }
            return """
                \(ask.map { "Change my Euclid settings: \($0)" } ?? "Help me set up Euclid. Ask me what I'd like it to do, and suggest 3 to 5 things that would suit me.")

                Use the euclid tools: euclid_config for my current setup, euclid_guide (settings) for what's possible, \
                then edit the files and check with euclid_config.
                """
        },
        .init(name: "plugin", description: "Make a Euclid plugin",
              arguments: [.init(name: "what", description: "What it should add to the bar, e.g. \"my open GitLab MRs\"", required: true)]) { args in
            """
            Make me a Euclid plugin: \(args["what"] ?? "")

            Use the euclid tools: euclid_guide (plugins) for the format, euclid_config for what I already have. \
            Write it under my plugins folder, try it with --try-plugin, and fix what it prints.
            """
        },
    ] }

    /// What `euclid_config` returns: what `--check-config` prints, plus the file itself.
    static func report(paths: EuclidPaths, readFile: (URL) -> String?) -> String {
        let file = ProjectScanner.abbreviate(paths.configFile.path)
        guard let text = readFile(paths.configFile) else {
            return "No config file at \(file) yet: Euclid writes a commented default on first launch. "
                + "Create it with only the settings the user wants (euclid_guide settings lists them all)."
        }
        var lines = ["config: \(file)"]
        do {
            let loaded = try ConfigLoader.parse(text, directory: paths.configDirectory)
            let c = loaded.config
            lines += loaded.includedFiles.map { "include: \(ProjectScanner.abbreviate($0))" }
            lines.append("plugin folders: " + c.pluginDirectories.map { ProjectScanner.abbreviate($0) }.joined(separator: ", "))
            if c.plugins.isEmpty { lines.append("plugins: none installed") }
            for p in c.plugins {
                let parts = [p.source.map { _ in "source" }, p.answer.map { _ in "answer" }, p.badge.map { _ in "badge" },
                             p.actions.isEmpty ? nil : "\(p.actions.count) action(s)"].compactMap { $0 }
                lines.append("plugin: \(p.id) (\(p.name)) [\(parts.joined(separator: ", "))] \(ProjectScanner.abbreviate(p.directory))")
            }
            if !c.pluginsDisabled.isEmpty { lines.append("disabled plugins: " + c.pluginsDisabled.sorted().joined(separator: ", ")) }
            lines.append(loaded.issues.isEmpty ? "problems: none" : "problems:")
            lines += loaded.issues.map { "- \($0)" }
        } catch {
            lines += ["problems:", "- error: \(error) (Euclid keeps its last good settings until this is fixed)"]
        }
        let body = text.count > maxConfig ? String(text.prefix(maxConfig)) + "\n…(cut)" : text
        lines += ["", "config.toml:", "```toml", body.hasSuffix("\n") ? String(body.dropLast()) : body, "```"]
        return lines.joined(separator: "\n")
    }

    static func withoutMarker(_ guide: String) -> String {
        guide.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().joined().trimmingCharacters(in: .newlines)
    }
}
