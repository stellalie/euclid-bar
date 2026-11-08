import Foundation
import EuclidCore
import os

/// Opt-in daily "in use" ping (`[privacy] usage_ping = true`), so installs can be counted.
/// Sends `UsagePing` once per UTC day while Euclid runs; the install ID is made when it's turned on
/// and deleted when it's turned off. The last one sent is saved to ~/Library/Logs/Euclid/Reports.
@MainActor
final class UsagePinger {
    static let shared = UsagePinger()
    static let endpoint = URL(string: "https://reports.lgtm.ninja/v1/ping")!

    private let log = Logger(subsystem: "dev.euclid", category: "reports")
    private let defaults = UserDefaults.standard
    private let idKey = "usagePingID"
    private let lastSentKey = "usagePingLastSent"
    private var enabled = false
    private var channel = "stable"
    private var sending = false
    private var timer: Timer?

    func apply(enabled: Bool, channel: UpdateSettings.Channel) {
        self.enabled = enabled
        self.channel = channel.rawValue
        guard enabled else {
            timer?.invalidate()
            timer = nil
            defaults.removeObject(forKey: idKey)   // turning it back on counts as a new install
            defaults.removeObject(forKey: lastSentKey)
            return
        }
        if defaults.string(forKey: idKey) == nil { defaults.set(UsagePing.newID(), forKey: idKey) }
        if timer == nil {
            // Euclid stays open for days: check hourly so each day in use counts once.
            timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                Task { @MainActor in UsagePinger.shared.sendIfDue() }
            }
        }
        sendIfDue()
    }

    private func sendIfDue() {
        guard enabled, !sending, let id = defaults.string(forKey: idKey),
              UsagePing.isDue(lastSent: defaults.object(forKey: lastSentKey) as? Date, now: Date()) else { return }
        let ping = UsagePing(id: id, app: Updater.version, build: CrashReporter.build, channel: channel,
                             os: CrashReporter.os, arch: CrashReporter.arch)
        let body = ping.json()
        let saved = CrashReporter.shared.savedReports
        do {
            try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
            try body.write(to: saved.appending(path: "usage-ping.json"))
        } catch {
            log.error("can't save usage ping: \(error.localizedDescription, privacy: .public)")
        }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        sending = true
        let log = log
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200..<300).contains(status)
            if let error { log.error("usage ping not sent: \(error.localizedDescription, privacy: .public)") }
            else if !ok { log.error("usage ping not sent: HTTP \(status)") }
            Task { @MainActor in
                let pinger = UsagePinger.shared
                pinger.sending = false
                // Only count the day once it went through, and only if it wasn't turned off meanwhile.
                if ok, pinger.enabled, pinger.defaults.string(forKey: pinger.idKey) == id {
                    pinger.defaults.set(Date(), forKey: pinger.lastSentKey)
                }
            }
        }.resume()
    }
}
