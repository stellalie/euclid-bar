import Foundation
import Sparkle

/// Sparkle auto-update. Off unless the bundle carries a feed signing key
/// (release builds stamp `SUPublicEDKey`), so dev builds and `swift run` never check.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isEnabled: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
