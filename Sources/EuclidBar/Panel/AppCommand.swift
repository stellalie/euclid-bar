import EuclidCore

/// Something euclid-bar itself does, found by searching like anything else ("update").
struct AppCommand: Equatable {
    enum Kind: String { case checkForUpdates, toggleAutoInstall, buyLicence, enterLicence, importLauncher, showUsage, connectAgents }
    let kind: Kind
    let title: String
    var detail = ""
    let symbol: String
    /// Right-hand label: "On"/"Off" for a toggle.
    var accessory = ""

    static let importLauncher = AppCommand(kind: .importLauncher, title: "Import from Raycast or Alfred…",
                                           detail: "Snippets and quicklinks into config.toml", symbol: "square.and.arrow.down")

    static let connectAgents = AppCommand(kind: .connectAgents, title: "Connect Claude Code or Codex (MCP)…",
                                          detail: "Let your agents search your clipboard, pages and notes", symbol: "point.3.connected.trianglepath.dotted")

    /// How much you used Euclid lately, once there's something to show.
    static func usage(receipt: String?) -> [AppCommand] {
        receipt.map { [AppCommand(kind: .showUsage, title: "Usage: Your Last 30 Days", detail: $0, symbol: "chart.bar")] } ?? []
    }

    /// The update commands for the current `[updates]` settings.
    static func updates(_ settings: UpdateSettings, version: String, enabled: Bool) -> [AppCommand] {
        let note = enabled ? "euclid-bar \(version)" : "Local build: updates are off"
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
            AppCommand(kind: .buyLicence, title: "Buy Euclid Licence", detail: "\(summary) · opens euclid.lgtmworks.com",
                       symbol: "cart"),
            AppCommand(kind: .enterLicence, title: "Enter Licence Key", detail: summary, symbol: "key"),
        ]
    }
}
