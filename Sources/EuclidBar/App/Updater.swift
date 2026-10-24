import Foundation
import EuclidCore
import Sparkle

/// Sparkle auto-update. Off unless the bundle carries a feed signing key
/// (release builds stamp `SUPublicEDKey`), so local builds and `swift run` never check.
/// `[updates]` in config.toml drives it: Sparkle's own saved preferences just mirror the file.
@MainActor
final class Updater {
    /// The rolling pre-release that every green merge to main publishes (`.github/workflows/dev-release.yml`).
    /// Stable reads `SUFeedURL` from Info.plist.
    static let devFeed = "https://github.com/stellalie/euclid-bar-releases/releases/download/dev/appcast.xml"

    private let controller: SPUStandardUpdaterController?
    private let feed = FeedChooser()
    private var started = false

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty ? nil
            : SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: feed, userDriverDelegate: nil)
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
        feed.url = settings.channel == .dev ? Self.devFeed : nil
        updater.automaticallyChecksForUpdates = settings.check
        updater.automaticallyDownloadsUpdates = settings.autoInstall
        if !started {
            started = true
            controller?.startUpdater()
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

/// Sparkle asks before every check, so switching channel takes effect on the next one.
/// Build numbers keep rising across both channels, so leaving dev just waits for the next release.
private final class FeedChooser: NSObject, SPUUpdaterDelegate {
    nonisolated(unsafe) var url: String? // set and read on the main thread

    func feedURLString(for updater: SPUUpdater) -> String? { url }
}
