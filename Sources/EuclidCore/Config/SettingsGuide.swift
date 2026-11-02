import Foundation

/// Settings anyone can change by asking an AI ("make the bar bigger", "show my Jira issues"),
/// with the files in `~/.config/euclid` still the one source of truth. Euclid calls no AI itself:
/// - `prompt(current:)` is what "Change Settings with AI…" shows, to copy into any AI chat. The AI
///   reads the docs, asks what you want, and replies with a whole config.toml to paste in Edit Config.
/// - `guide` is `<config>/AGENTS.md`, for coding agents that edit the files directly.
public enum SettingsGuide {
    static let marker = "<!-- Written by Euclid; it's replaced on update. Put your own notes in another file. -->"

    /// Write `AGENTS.md` next to config.toml unless you replaced it with your own.
    public static func install(in configDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let url = configDirectory.appendingPathComponent("AGENTS.md")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            guard existing.hasPrefix(marker), existing != guide else { return } // yours, or current
        }
        try guide.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Where an AI reads what Euclid can do: every feature, setting and plugin.
    public static let docsURL = "https://lgtm.ninja/euclid/docs/"
    public static let pluginGuideURL = "https://lgtm.ninja/euclid/plugins/AGENTS.md"

    /// The rules any AI follows, chat or coding agent.
    static let rules = """
        - Keep everything I didn't ask to change, including my comments and order.
        - Use only settings from the docs, plus `[plugin.<id>]` tables for a plugin's settings. Don't invent keys.
        - Commands in `run` and scripts run on my Mac. Only add what I asked for, and say what each does.
        - Never put passwords or tokens in a file: read them from the Keychain (`security find-generic-password -s <service> -w`).
        - If Euclid can't do something, say so instead of guessing.
        """

    public static let guide = """
        \(marker)
        # Euclid settings: a guide for people and AI agents

        Everything Euclid does is set in this folder: `config.toml`, plus plugins in `plugins/`
        and helper scripts in `bin/` (on PATH for every action). Edit and save: Euclid reloads at once.
        A broken file never breaks the app; it keeps the last good settings and says what's wrong in the footer.

        ## Changing settings (coding agents)

        1. Edit `config.toml` in place, from what the user asked in plain words.
           New things in the bar (items from a script, answers, badges, keys): that's a plugin,
           and `plugins/AGENTS.md` is the whole format.
        2. Check: `/Applications/Euclid.app/Contents/MacOS/euclid-bar --check-config` (exit 0 = clean),
           and for a plugin `euclid-bar --try-plugin <id> [query]`. Fix everything they print.
        3. Tell the user what changed in one or two sentences.

        \(rules)
        - Don't touch `~/Library/Application Support/Euclid`: that's the app's own data, not settings.

        No coding agent? In Euclid, search "settings" and choose Change Settings with AI…: it shows
        a prompt for any AI chat, which replies with a whole config.toml to paste in Edit Config…

        ## Reference: every setting, with comments

        ```toml
        \(DefaultConfig.text)
        ```

        """

    /// The prompt "Change Settings with AI…" shows: what the AI should do, where the docs are,
    /// and the user's config.toml, so its reply can be the whole file.
    public static func prompt(current: String) -> String {
        """
        You're helping me set up Euclid, a search bar for my Mac (menu bar icon, opens with a hotkey). \
        All its settings are in one file, ~/.config/euclid/config.toml. My current file is at the end.

        1. Read the docs: \(docsURL) (every feature and setting). If you can't open links, use the \
        comments in my config.toml, which explain every setting.
        2. Ask me what I'd like Euclid to do. Suggest 3 to 5 things it can do that would suit me, \
        in plain words, e.g. a theme, apps or folders to search, snippets, web searches, a hotkey.
        3. When I've chosen, reply with my whole config.toml in one code block, never just the changed part, \
        and say in one or two sentences what changed. I'll open it from Euclid's menu bar icon \
        (Edit Config…), replace everything with your version, and save. Euclid applies it at once and \
        shows any problem at the bottom of its window.
        4. Things from another app or website in search, or a status badge on the bar, need a plugin. \
        Its format is at \(pluginGuideURL). Give me each file in full with the exact folder to save it in, \
        inside ~/.config/euclid/plugins/.

        Rules:
        \(rules)

        ## My current config.toml

        ```toml
        \(trimmed(current))
        ```

        """
    }

    /// "Fix Settings with AI…": the problems Euclid found and the file, for any AI chat.
    public static func fixPrompt(_ problems: [String], current: String) -> String {
        """
        Euclid, a search bar for my Mac, found problems in its settings file ~/.config/euclid/config.toml:
        \(problems.map { "- \($0)" }.joined(separator: "\n"))

        Every setting is explained at \(docsURL). Please fix only these problems, then reply with my whole \
        config.toml in one code block, never just the changed part, and say in one sentence what you fixed. \
        I'll paste it over the file in Edit Config… and save.

        Rules:
        \(rules)

        ## My current config.toml

        ```toml
        \(trimmed(current))
        ```

        """
    }

    private static func trimmed(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }
}
