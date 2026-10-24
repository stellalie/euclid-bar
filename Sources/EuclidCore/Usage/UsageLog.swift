import Foundation

/// How much you use Euclid, counted per day on your Mac (`usage.json` in the data folder).
/// Feeds the "last 30 days" receipt that the trial reminder and the usage command show.
/// Only counts: never what you typed or picked.
public struct UsageLog: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var opens = 0
        /// Picks by kind ("apps", "clips", "actions"…).
        public var picks: [String: Int] = [:]
    }

    /// Keyed by local date, "2026-10-24".
    public private(set) var days: [String: Day] = [:]
    /// Older days are dropped.
    public static let keepDays = 90

    public init() {}

    public mutating func recordOpen(at now: Date = Date(), calendar: Calendar = .current) {
        days[Self.key(now, calendar), default: Day()].opens += 1
    }

    public mutating func recordPick(_ kind: String, at now: Date = Date(), calendar: Calendar = .current) {
        days[Self.key(now, calendar), default: Day()].picks[kind, default: 0] += 1
        prune(now: now, calendar: calendar)
    }

    public struct Summary: Equatable, Sendable {
        public var opens = 0
        public var activeDays = 0
        public var picks: [String: Int] = [:]
        public var totalPicks: Int { picks.values.reduce(0, +) }

        /// "412 opens on 21 days · 120 apps, 80 clips, 38 actions", or nil before any use.
        public var receipt: String? {
            guard opens > 0 || totalPicks > 0 else { return nil }
            let top = picks.filter { $0.value > 0 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(4).map { "\($0.value.formatted()) \($0.value == 1 && $0.key.hasSuffix("s") ? String($0.key.dropLast()) : $0.key)" }
            let head = "\(opens.formatted()) open\(opens == 1 ? "" : "s") on \(activeDays) day\(activeDays == 1 ? "" : "s")"
            return top.isEmpty ? head : "\(head) · \(top.joined(separator: ", "))"
        }
    }

    /// Totals for the last `days` days, today included.
    public func summary(days count: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> Summary {
        var s = Summary()
        let today = calendar.startOfDay(for: now)
        for offset in 0..<count {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today),
                  let day = days[Self.key(date, calendar)] else { continue }
            s.opens += day.opens
            if day.opens > 0 || !day.picks.isEmpty { s.activeDays += 1 }
            s.picks.merge(day.picks, uniquingKeysWith: +)
        }
        return s
    }

    private mutating func prune(now: Date, calendar: Calendar) {
        guard days.count > Self.keepDays,
              let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: calendar.startOfDay(for: now)) else { return }
        let oldest = Self.key(cutoff, calendar)
        days = days.filter { $0.key >= oldest } // ISO dates sort as strings
    }

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func load(from url: URL) -> UsageLog {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(UsageLog.self, from: $0) } ?? UsageLog()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
