import Foundation
import EuclidCore
import Sparkle

/// Sparkle auto-update. Off unless the bundle carries a feed signing key
/// (release builds stamp `SUPublicEDKey`), so dev builds and `swift run` never check.
/// `[updates]` in config.toml drives it: Sparkle's own saved preferences just mirror the file.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?
    private var started = false

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty ? nil
            : SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isEnabled: Bool { controller != nil }

    /// "1.2.0", or "dev" for an unversioned build.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Apply `[updates]`. The first call starts the updater, after the settings are in,
    /// so Sparkle never asks "check automatically?": config.toml already says.
    func apply(_ settings: UpdateSettings) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = settings.check
        updater.automaticallyDownloadsUpdates = settings.autoInstall
        if !started {
            started = true
            controller?.startUpdater()
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
