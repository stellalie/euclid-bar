import EuclidCore

/// Something euclid-bar itself does, found by searching like anything else ("update").
struct AppCommand: Equatable {
    enum Kind: String { case checkForUpdates, toggleAutoInstall, toggleExpansion, toggleOpenAtLogin, toggleDiagnostics, buyLicence, enterLicence, permissions, changeSettingsWithAI, fixSettings }
    let kind: Kind
    let title: String
    var detail = ""
    let symbol: String
    /// Right-hand label: "On"/"Off" for a toggle.
    var accessory = ""

    /// Vibe-coded settings: a prompt for any AI chat, whose reply you paste in Edit Config.
    /// `problems`: the config has issues (adds Fix).
    static func settingsWithAI(problems: Bool) -> [AppCommand] {
        [AppCommand(kind: .changeSettingsWithAI, title: "Change Settings with AI…",
                    detail: "A prompt for ChatGPT, Copilot, Claude or any AI chat", symbol: "wand.and.stars")]
        + (problems ? [AppCommand(kind: .fixSettings, title: "Fix Settings with AI…",
                                  detail: "A prompt with the problems and your config.toml, for any AI chat", symbol: "wrench.and.screwdriver")] : [])
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

    /// Opt-in crash reports and daily usage ping as one switch (`[privacy] crash_reports`, `usage_ping`).
    static func diagnostics(crashReports: Bool, usagePing: Bool) -> AppCommand {
        let accessory = crashReports && usagePing ? "On" : crashReports || usagePing ? "Partly on" : "Off"
        return AppCommand(kind: .toggleDiagnostics, title: "Share Anonymous Diagnostics",
                          detail: "Crash reports and a daily install ping, never your data · [privacy]",
                          symbol: "stethoscope", accessory: accessory)
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
