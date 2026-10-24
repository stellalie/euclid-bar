import EuclidCore

/// Something euclid-bar itself does, found by searching like anything else ("update").
struct AppCommand: Equatable {
    enum Kind: String { case checkForUpdates, toggleAutoInstall, buyLicence, enterLicence, importLauncher }
    let kind: Kind
    let title: String
    var detail = ""
    let symbol: String
    /// Right-hand label: "On"/"Off" for a toggle.
    var accessory = ""

    static let importLauncher = AppCommand(kind: .importLauncher, title: "Import from Raycast or Alfred…",
                                           detail: "Snippets and quicklinks into config.toml", symbol: "square.and.arrow.down")

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
