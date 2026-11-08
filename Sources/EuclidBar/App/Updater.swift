import Foundation
import EuclidCore
import Sparkle

/// Sparkle auto-update. Off unless the bundle carries a feed signing key
/// (release builds stamp `SUPublicEDKey`), so local builds and `swift run` never check.
/// `[updates]` in config.toml drives it: Sparkle's own saved preferences just mirror the file.
@MainActor
final class Updater {
    /// The rolling pre-release that every green merge to main publishes (`scripts/publish-release.sh`).
    /// Stable reads `SUFeedURL` from Info.plist.
    static let devFeed = "https://github.com/stellalie/euclid-bar-releases/releases/download/dev/appcast.xml"

    /// How often to look: dev builds land several times a day, stable ones every few days.
    static func checkInterval(for channel: UpdateSettings.Channel) -> TimeInterval {
        channel == .dev ? 3600 : 6 * 3600 // Sparkle's minimum is an hour
    }

    /// True while installing would interrupt you (the panel is open). The install waits for `installIfReady()`.
    var isBusy: () -> Bool = { false }

    private let controller: SPUStandardUpdaterController?
    private let delegate = UpdaterDelegate()
    private var started = false

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty ? nil
            : SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        delegate.ready = { [weak self] in self?.installIfReady() }
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
        delegate.url = settings.channel == .dev ? Self.devFeed : nil
        updater.automaticallyChecksForUpdates = settings.check
        updater.automaticallyDownloadsUpdates = settings.autoInstall
        updater.updateCheckInterval = Self.checkInterval(for: settings.channel)
        if !started {
            started = true
            controller?.startUpdater()
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// A launcher never quits, so Sparkle's "install on quit" would never come: install a downloaded
    /// update (and relaunch) as soon as the panel is closed.
    func installIfReady() {
        guard !isBusy(), let install = delegate.pendingInstall else { return }
        delegate.pendingInstall = nil
        install()
    }
}

/// Picks the feed (Sparkle asks before every check, so switching channel takes effect on the next one;
/// build numbers keep rising across both channels, so leaving dev just waits for the next release)
/// and takes over installing silently downloaded updates.
@MainActor // Sparkle's delegate protocol is main-actor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var url: String?
    var pendingInstall: (() -> Void)?
    var ready: (() -> Void)?

    func feedURLString(for updater: SPUUpdater) -> String? { url }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallHandler
        Task { @MainActor [weak self] in self?.ready?() } // after Sparkle has its answer
        return true
    }
}
