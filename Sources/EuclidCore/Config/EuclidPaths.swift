import Foundation

/// Where Euclid keeps things.
/// - Config (you edit, dotfiles-safe): `$EUCLID_CONFIG_DIR` › `$XDG_CONFIG_HOME/euclid` › `~/.config/euclid`
/// - Data (private, app-managed):      `$EUCLID_DATA_DIR`   › `~/Library/Application Support/Euclid`
public struct EuclidPaths: Sendable {
    public let configDirectory: URL
    public let dataDirectory: URL

    public var configFile: URL { configDirectory.appendingPathComponent("config.toml") }
    /// Helper scripts; on PATH for every action.
    public var binDirectory: URL { configDirectory.appendingPathComponent("bin") }
    public var historyDatabase: URL { dataDirectory.appendingPathComponent("history.sqlite") }

    public init(environment env: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let dir = env["EUCLID_CONFIG_DIR"], !dir.isEmpty {
            configDirectory = URL(fileURLWithPath: dir)
        } else if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configDirectory = URL(fileURLWithPath: xdg).appendingPathComponent("euclid")
        } else {
            configDirectory = home.appendingPathComponent(".config/euclid")
        }
        if let dir = env["EUCLID_DATA_DIR"], !dir.isEmpty {
            dataDirectory = URL(fileURLWithPath: dir)
        } else {
            dataDirectory = home.appendingPathComponent("Library/Application Support/Euclid")
        }
    }
}
