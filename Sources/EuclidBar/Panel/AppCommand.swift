import EuclidCore

/// Something euclid-bar itself does, found by searching like anything else ("update").
struct AppCommand: Equatable {
    enum Kind: String { case checkForUpdates, toggleAutoInstall, toggleExpansion, toggleOpenAtLogin, toggleCrashReports, toggleUsagePing, buyLicence, enterLicence, connectAgents, permissions, changeSettingsWithAI, applySettings, copyPluginGuide, fixSettings, restoreSettings }
    let kind: Kind
    let title: String
    var detail = ""
    let symbol: String
    /// Right-hand label: "On"/"Off" for a toggle.
    var accessory = ""

    static let connectAgents = AppCommand(kind: .connectAgents, title: "Connect Claude Code or Codex (MCP)…",
                                          detail: "Let your agents search your clipboard, notes and history", symbol: "point.3.connected.trianglepath.dotted")

    /// Vibe-coded settings: copy a prompt for any AI chat, then apply its reply.
    /// `problems`: the config has issues (adds Fix). `canRestore`: a backup exists (adds Restore).
    static func settingsWithAI(problems: Bool, canRestore: Bool) -> [AppCommand] {
        [AppCommand(kind: .changeSettingsWithAI, title: "Change Settings with AI…",
                    detail: "Copies a prompt for ChatGPT, Copilot, Claude or any AI chat", symbol: "wand.and.stars"),
         AppCommand(kind: .applySettings, title: "Apply Settings from Clipboard",
                    detail: "Paste back the AI's reply · checked before saving, with Undo", symbol: "doc.on.clipboard"),
         AppCommand(kind: .copyPluginGuide, title: "Copy Plugin Guide for AI",
                    detail: "When the AI asks for it: new things in the bar need a plugin", symbol: "puzzlepiece.extension")]
        + (problems ? [AppCommand(kind: .fixSettings, title: "Fix Settings with AI…",
                                  detail: "Copies the problems and your config.toml for any AI chat", symbol: "wrench.and.screwdriver")] : [])
        + (canRestore ? [AppCommand(kind: .restoreSettings, title: "Restore Previous Settings…",
                                    detail: "Undo the last Apply Settings from Clipboard", symbol: "arrow.uturn.backward")] : [])
    }

    /// Every permission Euclid uses, in one row: ↵ opens the pane for the first one missing.
    static func permissions(_ needs: [Permissions.Need]) -> AppCommand {
        AppCommand(kind: .permissions, title: "Permissions", detail: Permissions.summary(needs), symbol: "lock.shield",
                   accessory: needs.isEmpty ? "OK" : "\(needs.count) missing")
    }

    /// Snippet keywords expanding in any app (`[expansion] enabled`).
    static func expansion(enabled: Bool) -> AppCommand {
        AppCommand(kind: .toggleExpansion, title: "Text Expansion", detail: "Type a snippet keyword in any app · [expansion] enabled",
                   symbol: "text.cursor", accessory: enabled ? "On" : "Off")
    }

    /// Start at login (`[startup] open_at_login`), as macOS has it now.
    static func openAtLogin(enabled: Bool) -> AppCommand {
        AppCommand(kind: .toggleOpenAtLogin, title: "Open at Login", detail: "Start Euclid when you log in · [startup] open_at_login",
                   symbol: "person.crop.circle", accessory: enabled ? "On" : "Off")
    }

    /// Opt-in crash and error reports (`[privacy] crash_reports`).
    static func crashReports(enabled: Bool) -> AppCommand {
        AppCommand(kind: .toggleCrashReports, title: "Send Crash Reports", detail: "Stack and versions only, never your data · [privacy] crash_reports",
                   symbol: "ladybug", accessory: enabled ? "On" : "Off")
    }

    /// Opt-in daily anonymous ping (`[privacy] usage_ping`).
    static func usagePing(enabled: Bool) -> AppCommand {
        AppCommand(kind: .toggleUsagePing, title: "Send Anonymous Usage Ping", detail: "Random install ID and versions, once a day · [privacy] usage_ping",
                   symbol: "chart.bar", accessory: enabled ? "On" : "Off")
    }

    /// The update commands for the current `[updates]` settings.
    static func updates(_ settings: UpdateSettings, version: String, enabled: Bool) -> [AppCommand] {
        let note = enabled ? "Euclid \(version)" : "Local build: updates are off"
        return [
            AppCommand(kind: .checkForUpdates, title: "Check for Updates", detail: note, symbol: "arrow.down.circle"),
            AppCommand(kind: .toggleAutoInstall, title: "Install Updates Automatically",
                       detail: "[updates] auto_install", symbol: "arrow.triangle.2.circlepath",
                       accessory: settings.autoInstall ? "On" : "Off"),
        ]
    }

    /// Buying and registering, until a licence is in.
    static func licence(summary: String, licensed: Bool) -> [AppCommand] {
        guard !licensed else { return [] }
        return [
            AppCommand(kind: .buyLicence, title: "Buy Euclid Licence", detail: "\(summary) · opens lgtm.ninja/euclid",
                       symbol: "cart"),
            AppCommand(kind: .enterLicence, title: "Enter Licence Key", detail: summary, symbol: "key"),
        ]
    }
}
