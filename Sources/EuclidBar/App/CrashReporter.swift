import Foundation
import EuclidCore
import os

/// Opt-in crash and error reports (`[privacy] crash_reports = true`).
/// Crashes: macOS writes a crash log; on the next launch Euclid sends the parts in `CrashReport`.
/// Errors: the internal failures that break a feature (a store that won't open), once per launch each.
/// Only reports made while it's on are sent, and each is saved to ~/Library/Logs/Euclid/Reports first.
@MainActor
final class CrashReporter {
    static let shared = CrashReporter()
    static let endpoint = URL(string: "https://reports.lgtm.ninja/v1/report")!

    private let log = Logger(subsystem: "dev.euclid", category: "reports")
    private let defaults = UserDefaults.standard
    private let sinceKey = "crashReportsSince"   // reports made before this aren't sent
    private var enabled = false
    private var channel = "stable"
    private var scanned = false
    private var sentErrors: Set<String> = []
    /// Errors from before `apply` (launch order), sent once the setting is known.
    private var early: [(String, String)] = []
    private var configured = false

    private let crashLogs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
    let savedReports = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Euclid/Reports")

    func apply(enabled: Bool, channel: UpdateSettings.Channel) {
        self.enabled = enabled
        self.channel = channel.rawValue
        if !enabled {
            defaults.removeObject(forKey: sinceKey) // turning it back on never sends what happened while off
        } else if defaults.object(forKey: sinceKey) == nil {
            defaults.set(Date(), forKey: sinceKey)
        }
        if !configured {
            configured = true
            let pending = early
            early = []
            for (category, message) in pending { error(category, message) }
        }
        if enabled && !scanned {
            scanned = true
            sendNewCrashes()
        }
    }

    /// Reports an internal error, if reports are on. Call next to the `log.error` for it.
    nonisolated static func error(_ category: String, _ message: String) {
        Task { @MainActor in shared.error(category, message) }
    }

    private func error(_ category: String, _ message: String) {
        guard configured else { early.append((category, message)); return }
        guard enabled else { return }
        let report = CrashReport(kind: .error, title: category, message: message, app: Updater.version,
                                 build: Self.build, channel: channel, os: Self.os, arch: Self.arch)
        guard sentErrors.insert(report.fingerprint).inserted else { return }
        send(report, name: "error-\(report.fingerprint)")
    }

    /// Crash logs from this app since reports were turned on (and since the last one sent).
    private func sendNewCrashes() {
        guard let since = defaults.object(forKey: sinceKey) as? Date,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: crashLogs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var newest = since
        for file in files where file.lastPathComponent.hasPrefix("euclid-bar") && file.pathExtension == "ips" {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified > since,
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  let report = CrashReport.fromIPS(text, bundleID: bundleID, channel: channel) else { continue }
            newest = max(newest, modified)
            send(report, name: file.deletingPathExtension().lastPathComponent)
        }
        defaults.set(newest, forKey: sinceKey)
    }

    private func send(_ report: CrashReport, name: String) {
        let body = report.json()
        do {
            try FileManager.default.createDirectory(at: savedReports, withIntermediateDirectories: true)
            try body.write(to: savedReports.appending(path: "\(name).json"))
        } catch {
            log.error("can't save report: \(error.localizedDescription, privacy: .public)")
        }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let log = log
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error { log.error("report not sent: \(error.localizedDescription, privacy: .public)") }
            else if status >= 300 { log.error("report not sent: HTTP \(status)") }
            else { log.info("report sent: \(name, privacy: .public)") }
        }.resume()
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    static var os: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
