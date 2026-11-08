import Foundation

/// The once-a-day "this install is in use" ping, sent with `[privacy] usage_ping = true`.
/// A random install ID (made when the ping is turned on, dropped when it's turned off) and versions.
/// Nothing else: no name, account, licence, searches, files or config.
public struct UsagePing: Codable, Equatable, Sendable {
    /// Random, lowercase UUID. Not tied to the Mac, the user or the licence.
    public var id: String
    public var app: String
    public var build: String
    public var channel: String
    /// "macOS 15.1.0"; the server keeps only the major version.
    public var os: String
    public var arch: String

    public init(id: String, app: String, build: String, channel: String, os: String, arch: String) {
        self.id = id
        self.app = app
        self.build = build
        self.channel = channel
        self.os = os
        self.arch = arch
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// Keys sorted, so the saved copy reads the same as what went over the wire.
    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// One ping per UTC day: due when the last one went out on an earlier day (or never).
    public static func isDue(lastSent: Date?, now: Date) -> Bool {
        guard let lastSent else { return true }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return !utc.isDate(lastSent, inSameDayAs: now) && now > lastSent
    }
}
