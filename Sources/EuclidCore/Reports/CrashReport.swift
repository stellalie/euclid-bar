import CryptoKit
import Foundation

/// One crash or internal error, as sent with `[privacy] crash_reports = true`.
/// Holds only what helps fix the bug: versions, the stack, the error text. Never queries,
/// clipboard, file contents, config or anything that identifies you; home paths become `~`.
public struct CrashReport: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case crash, error }

    public var kind: Kind
    /// "EXC_BREAKPOINT (SIGTRAP)" for a crash, the log category ("clipboard") for an error.
    public var title: String
    /// Swift's "Fatal error: …", the exception reason, or the error message.
    public var message: String
    /// The crashed thread, top first: "euclid-bar  LauncherViewController.reload() + 120".
    public var frames: [String]
    public var app: String
    public var build: String
    public var channel: String
    public var os: String
    public var arch: String
    /// Same bug, same fingerprint: the server folds repeats into one issue.
    public var fingerprint: String

    public static let maxFrames = 60
    static let maxMessage = 1_000

    public init(kind: Kind, title: String, message: String, frames: [String] = [],
                app: String, build: String, channel: String, os: String, arch: String) {
        self.kind = kind
        self.title = Self.scrub(title, limit: 200)
        self.message = Self.scrub(message, limit: Self.maxMessage)
        self.frames = frames.prefix(Self.maxFrames).map { Self.scrub($0, limit: 400) }
        self.app = app
        self.build = build
        self.channel = channel
        self.os = os
        self.arch = arch
        fingerprint = Self.fingerprint(kind: kind, title: self.title, message: self.message, frames: self.frames)
    }

    /// Keys sorted, so a saved copy reads the same as what went over the wire.
    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    // MARK: Privacy

    /// `/Users/<name>/…` → `~/…`, and length capped. Applied to every string a report carries.
    public static func scrub(_ s: String, limit: Int) -> String {
        var out = s.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "~", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>",
                                       options: .regularExpression)
        if out.count > limit { out = String(out.prefix(limit)) + "…" }
        return out
    }

    // MARK: Fingerprint

    /// Crashes: the top frames, without offsets (they move between builds).
    /// Errors: the category and the message with numbers taken out.
    static func fingerprint(kind: Kind, title: String, message: String, frames: [String]) -> String {
        let key: String
        switch kind {
        case .crash:
            let top = frames.prefix(8).map { $0.replacingOccurrences(of: #"\s*\+\s*(0x)?[0-9a-fA-F]+$"#, with: "",
                                                                    options: .regularExpression) }
            key = ([title] + top).joined(separator: "\n")
        case .error:
            key = title + "\n" + message.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        }
        return SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - macOS crash logs

extension CrashReport {
    /// A report from a macOS crash log (`~/Library/Logs/DiagnosticReports/euclid-bar-*.ips`):
    /// a JSON header line, then the JSON body. Nil if it isn't one, or isn't from `bundleID`.
    public static func fromIPS(_ text: String, bundleID: String, channel: String) -> CrashReport? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = object(text[..<newline]),
              header["bundleID"] as? String == bundleID,
              let body = object(text[text.index(after: newline)...]) else { return nil }

        let exception = body["exception"] as? [String: Any] ?? [:]
        let type = exception["type"] as? String ?? "crash"
        let title = (exception["signal"] as? String).map { "\(type) (\($0))" } ?? type

        // "Fatal error: Index out of range" (Swift) or the uncaught exception's reason.
        let asi = (body["asi"] as? [String: [String]])?.values.flatMap { $0 } ?? []
        let termination = (body["termination"] as? [String: Any])?["indicator"] as? String
        let message = asi.isEmpty ? termination ?? "" : asi.joined(separator: "\n")

        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "???" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int
        let crashed = threads.first { $0["triggered"] as? Bool == true }
            ?? faulting.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
        // An uncaught exception's own backtrace says where it was thrown; the thread just shows the abort.
        let raw = body["lastExceptionBacktrace"] as? [[String: Any]] ?? crashed?["frames"] as? [[String: Any]] ?? []
        let frames = raw.map { frame(frame: $0, images: images) }

        let version = header["app_version"] as? String ?? "?"
        let build = header["build_version"] as? String ?? "?"
        let os = (body["osVersion"] as? [String: Any]).flatMap { v in
            (v["train"] as? String).map { "\($0) (\(v["build"] as? String ?? "?"))" }
        } ?? header["os_version"] as? String ?? "?"
        let arch = body["cpuType"] as? String ?? "?"

        return CrashReport(kind: .crash, title: title, message: message, frames: frames,
                           app: version, build: build, channel: channel, os: os, arch: ["ARM-64": "arm64", "X86-64": "x86_64"][arch] ?? arch)
    }

    /// "euclid-bar  LauncherViewController.reload() + 120", or "libsystem_kernel.dylib  +0x1f2c" unsymbolicated.
    private static func frame(frame: [String: Any], images: [String]) -> String {
        let index = frame["imageIndex"] as? Int ?? -1
        let image = images.indices.contains(index) ? images[index] : "???"
        if let symbol = frame["symbol"] as? String {
            return "\(image)  \(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
        }
        return "\(image)  +0x\(String(frame["imageOffset"] as? Int ?? 0, radix: 16))"
    }

    private static func object(_ s: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }
}
