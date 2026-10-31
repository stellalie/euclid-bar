import AppKit
import EuclidCore
import ServiceManagement

/// Starts Euclid at login (`[startup] open_at_login`), through macOS's Login Items.
@MainActor
enum LoginItem {
    /// What macOS has now. Someone can switch it off in System Settings → General → Login Items.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Only a real Euclid.app can be a login item, not `swift run` or a test binary.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private static let appliedKey = "appliedOpenAtLogin"

    /// Applies the config's choice when it changed since it was last applied, so switching Euclid off
    /// in System Settings sticks until config.toml changes. `force` applies it regardless (the menu toggle).
    /// Returns a problem to show, or nil.
    @discardableResult
    static func apply(_ on: Bool, force: Bool = false) -> String? {
        guard isAvailable else { return nil }
        let last = UserDefaults.standard.object(forKey: appliedKey) as? Bool
        guard force || last != on else { return nil }
        let service = SMAppService.mainApp
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            let problem = "can't \(on ? "add Euclid to" : "remove Euclid from") Login Items: \(error.localizedDescription)"
            perfLog.error("\(problem, privacy: .public)")
            return problem
        }
        UserDefaults.standard.set(on, forKey: appliedKey)
        return nil
    }
}
