import AppKit
import EuclidCore
import ServiceManagement

/// Starts Euclid at login (`[startup] open_at_login`), through macOS's Login Items.
@MainActor
enum LoginItem {
    /// What Euclid last applied (or the config's choice, before the first apply).
    /// Deliberately not `SMAppService.mainApp.status`: asking macOS for it slowed every later panel open in
    /// that process from ~10 ms to ~100 ms (Perf runs, Nov 2026). Switching it off in System Settings
    /// isn't reflected here; the toggle still works, it just takes one extra press.
    static func isEnabled(default config: Bool) -> Bool {
        UserDefaults.standard.object(forKey: appliedKey) as? Bool ?? config
    }

    /// Only a real, installed Euclid.app can be a login item: not `swift run`, a test binary, or a copy
    /// opened from the disk image (it's gone after eject, and the setting would be marked as applied).
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && !InstallLocation.isTemporary(bundlePath: Bundle.main.bundleURL.path)
    }

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
            // No `status` check first (see isEnabled): "already registered" / "not registered" mean done.
            if on { try service.register() } else { try service.unregister() }
        } catch let error as NSError where error.code == Int(on ? kSMErrorAlreadyRegistered : kSMErrorJobNotFound) {
            // already in the state we want
        } catch {
            let problem = "can't \(on ? "add Euclid to" : "remove Euclid from") Login Items: \(error.localizedDescription)"
            perfLog.error("\(problem, privacy: .public)")
            return problem
        }
        UserDefaults.standard.set(on, forKey: appliedKey)
        return nil
    }
}
