import AppKit
import EuclidCore

/// The dialogs of Change Settings with AI, shared by the app and `--render-screens`.
@MainActor
enum SettingsDialogs {
    static func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        for b in buttons { alert.addButton(withTitle: b) }
        return alert
    }

    static let promptCopied = (title: "Prompt copied", text: """
        1. Paste it into ChatGPT, Copilot, Claude or any AI chat, and type what you want at the end, \
        e.g. “use the Nord theme and open my projects in VS Code”.
        2. Copy the AI's whole reply.
        3. In Euclid, search “settings” and choose Apply Settings from Clipboard. \
        You'll see every change before anything is saved.

        If the AI asks for the plugin guide, choose Copy Plugin Guide for AI and paste that too.

        The prompt includes your config.toml. If you put anything private in it, look it over first.
        """)

    static func rejected(_ rejection: SettingsChange.Rejection) -> String {
        rejection.description + "\n\nCopy a note for the AI, paste it into the same chat, then apply its new reply."
    }
    static let rejectedButtons = ["Copy Note for the AI", "Close"]

    static let confirmTitle = "Apply these changes?"
    static let confirmButtons = ["Apply", "Cancel"]

    static let applied = (title: "Settings applied", text: "They're live now. Search “restore” to put the previous ones back any time.")
    static let appliedButtons = ["OK", "Undo"]

    /// Each file with its changed lines ("− theme = …" / "+ theme = …"), scripts in full.
    static func summary(of review: SettingsChange.Review) -> String {
        var parts: [String] = []
        for file in review.files {
            let head = "\(file.path)\(file.isNew ? " (new)" : "")"
            if file.isScript {
                let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
                parts.append("\(head): a script that runs on your Mac\n" + lines.prefix(15).joined(separator: "\n")
                             + (lines.count > 15 ? "\n… and \(lines.count - 15) more lines" : ""))
                continue
            }
            // Without trailing comments: the setting is what changed, and long ones wrap.
            func code(_ line: String) -> String {
                line.replacingOccurrences(of: #"\s{2,}#.*$"#, with: "", options: .regularExpression)
            }
            let lines = file.removed.map { "− \(code($0))" } + file.added.map { "+ \(code($0))" }
            let limit = 12
            parts.append(lines.isEmpty ? "\(head): only comments or layout"
                         : "\(head)\n" + lines.prefix(limit).joined(separator: "\n") + (lines.count > limit ? "\n… and \(lines.count - limit) more" : ""))
        }
        if review.looksPartial {
            parts.append("⚠︎ This removes a lot from config.toml. AI chats sometimes send only the changed part: "
                         + "if that's what happened, cancel and ask for the complete file.")
        }
        if review.files.contains(where: \.isScript) {
            parts.append("Scripts can do anything your account can. Apply only if you asked for them.")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: --render-screens

    /// Each step of the flow, as the real dialogs, from a sample reply checked like the app does.
    static func renderFlow(to dir: URL, snapshot: (NSView) -> CGImage, write: (CGImage, String, String) throws -> Void) throws {
        let fm = FileManager.default
        let config = fm.temporaryDirectory.appendingPathComponent("euclid-render-settings-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: config) }
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try DefaultConfig.text.write(to: config.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try SettingsGuide.prompt(current: DefaultConfig.text)
            .appending("Use the Nord theme, open my projects in VS Code, and show the weather on the bar.\n")
            .write(to: dir.appendingPathComponent("settings-ai-prompt.txt"), atomically: true, encoding: .utf8)

        let edited = DefaultConfig.text
            .replacingOccurrences(of: #"theme      = "default""#, with: #"theme      = "nord""#)
            .replacingOccurrences(of: #"open  = 'open "$1"'"#, with: #"open  = 'code "$1"'"#)
        let reply = """
            Here's your updated settings.

            File: `config.toml`
            ```toml
            \(edited)
            ```

            File: `plugins/weather/plugin.toml`
            ```toml
            name = "Weather"
            description = "Today's weather on the bar, from wttr.in"

            [badge]
            run = "./now.sh"
            icon = "cloud.sun"
            refresh_minutes = 30
            ```

            File: `plugins/weather/now.sh`
            ```sh
            #!/bin/zsh
            # One line for the badge, e.g. "☀️ 21°C"
            curl -s --max-time 5 'https://wttr.in/?format=%c%t'
            ```

            I switched the theme to Nord, made projects open in VS Code, and added a weather badge.
            """
        guard case .success(let review) = SettingsChange.review(reply, directory: config) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "the sample reply didn't pass its own check"])
        }
        guard case .failure(let rejection) = SettingsChange.review(edited.replacingOccurrences(of: #"density    = "comfortable""#, with: #"density    = "huge""#), directory: config) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "the broken sample reply passed"])
        }

        let steps: [(String, NSAlert, String)] = [
            ("settings-1-copied", alert(promptCopied.title, promptCopied.text), "1. Change Settings with AI… copies a prompt for any AI chat"),
            ("settings-2-confirm", alert(confirmTitle, summary(of: review), buttons: confirmButtons),
             "2. Apply Settings from Clipboard: every change and script, before saving"),
            ("settings-3-applied", alert(applied.title, applied.text, buttons: appliedButtons), "3. Live at once, with Undo"),
            ("settings-4-rejected", alert("Nothing changed", rejected(rejection), buttons: rejectedButtons),
             "A broken reply writes nothing, and gives a note for the AI"),
        ]
        let rep = IconRenderer.image(pixels: 256) // no app bundle when rendering, so no app icon
        let icon = NSImage(size: NSSize(width: 64, height: 64))
        icon.addRepresentation(rep)
        for (name, alert, caption) in steps {
            alert.icon = icon
            alert.layout()
            guard let view = alert.window.contentView else { continue }
            try write(snapshot(view), name, caption)
        }
    }
}
