import Foundation

/// Settings anyone can change by asking an AI ("make the bar bigger", "show my Jira issues"),
/// with the files in `~/.config/euclid` still the one source of truth. Euclid calls no AI itself:
/// - `prompt(current:)` is what "Change Settings with AI…" copies, for any AI chat;
///   `pluginPrompt` adds the plugin guide when the AI asks for it.
/// - `SettingsChange` checks and applies the reply ("Apply Settings from Clipboard").
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

    /// The rules any AI follows, chat or coding agent.
    static let rules = """
        - Keep everything the user didn't ask to change, including their comments and order.
        - Use only settings from the reference, plus `[plugin.<id>]` tables for a plugin's settings. Don't invent keys.
        - Commands in `run` and scripts run on the user's Mac. Only add what they asked for, and say what each does.
        - Never put passwords or tokens in a file: read them from the Keychain (`security find-generic-password -s <service> -w`).
        - If the request is unclear, or Euclid can't do it, say so instead of guessing.
        """

    /// How a chat reply carries files, so Apply Settings from Clipboard can find them.
    static let replyFormat = """
        - Reply with each file you change or add in full, never just the changed part, in its own code block.
        - On the line right before each code block, write its path, like: File: `config.toml`
          Paths are inside ~/.config/euclid: `config.toml`, `plugins/<id>/<file>`, `bin/<script>` or `themes/<name>.toml`.
        - A script starts with a `#!` line, e.g. `#!/bin/zsh`, so Euclid makes it runnable.
        - After the code blocks, say in one or two plain sentences what you changed.
        """

    /// What needs a plugin, in words a non-developer's request would use.
    static let needsPlugin = """
        - Things from another app or website in search, a reply to what's typed, a status badge on the bar, \
        or a key that runs something on the selected result need a plugin or a script. If that's what I want \
        and you don't have Euclid's plugin guide yet, don't guess the format: ask me for it. \
        (I copy it in Euclid with "Copy Plugin Guide for AI".)
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

        No coding agent? In Euclid, search "settings" and choose Change Settings with AI…:
        it copies a prompt for any AI chat, and Apply Settings from Clipboard checks the reply
        (settings, plugins and scripts) before saving, with Undo.

        ## Reference: every setting, with comments

        ```toml
        \(DefaultConfig.text)
        ```

        """

    /// The prompt "Change Settings with AI…" copies: rules, the commented reference, the
    /// user's file, and a last heading for them to finish with what they want.
    public static func prompt(current: String) -> String {
        let isDefault = current.trimmingCharacters(in: .whitespacesAndNewlines)
            == DefaultConfig.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The default file already is the reference: don't send it twice (chats limit prompt length).
        let reference = isDefault ? "" : """

            ## Reference: every setting, with comments

            ```toml
            \(DefaultConfig.text)
            ```

            """
        return """
            You're helping me change the settings of Euclid, a search bar for my Mac. Its settings are \
            text files in ~/.config/euclid, mainly config.toml. Below are the rules, \
            \(isDefault ? "my current config.toml (its comments explain every setting)" : "a commented reference of every setting, my current config.toml"), \
            and at the very end, what I want.

            Rules:
            \(replyFormat)
            \(rules)
            \(needsPlugin)

            I'll copy your whole reply and choose "Apply Settings from Clipboard" in Euclid, which checks it before saving.
            \(reference)
            ## My current config.toml

            ```toml
            \(trimmed(current))
            ```

            ## What I want

            """
    }

    /// "Copy Plugin Guide for AI": the plugin format, for the chat that asked for it.
    public static func pluginPrompt(guide: String) -> String {
        """
        Here's Euclid's plugin guide. Use it for what I asked, and reply the same way as before:
        \(replyFormat)

        \(trimmed(guide.replacingOccurrences(of: marker + "\n", with: "")))
        """
    }

    /// What to send back to the AI when its reply (or the file as it is) has problems.
    public static func fixPrompt(_ problems: [String], current: String? = nil) -> String {
        var text = """
            Euclid found problems in my settings:
            \(problems.map { "- \($0)" }.joined(separator: "\n"))

            Please fix them. Reply the same way as before:
            \(replyFormat)
            """
        if let current {
            text += """


                Rules:
                \(rules)

                ## My current config.toml

                ```toml
                \(trimmed(current))
                ```
                """
        }
        return text + "\n"
    }

    private static func trimmed(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }
}
