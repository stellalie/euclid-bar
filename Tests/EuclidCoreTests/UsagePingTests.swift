import Foundation
import Testing
@testable import EuclidCore

@Suite struct UsagePingTests {
    @Test func jsonIsWhatTheServerReads() throws {
        let ping = UsagePing(id: UsagePing.newID(), app: "1.3.0", build: "130", channel: "stable", os: "macOS 15.1.0", arch: "arm64")
        let object = try #require(try JSONSerialization.jsonObject(with: ping.json()) as? [String: Any])
        #expect(Set(object.keys) == ["id", "app", "build", "channel", "os", "arch"])
        #expect(ping.id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil)
    }

    @Test func oncePerUTCDay() {
        let day = ISO8601DateFormatter()
        let morning = day.date(from: "2026-10-31T00:05:00Z")!
        #expect(UsagePing.isDue(lastSent: nil, now: morning))
        #expect(!UsagePing.isDue(lastSent: morning, now: day.date(from: "2026-10-31T23:59:00Z")!))
        #expect(UsagePing.isDue(lastSent: morning, now: day.date(from: "2026-11-01T00:00:01Z")!))
        // A clock set back doesn't send twice.
        #expect(!UsagePing.isDue(lastSent: morning, now: day.date(from: "2026-10-30T12:00:00Z")!))
    }

    @Test func offByDefaultAndParsed() throws {
        #expect(!EuclidConfig().usagePing)
        #expect(!(try ConfigLoader.parse(DefaultConfig.text).config.usagePing))
        let on = try ConfigLoader.parse("[privacy]\nusage_ping = true\n")
        #expect(on.config.usagePing && !on.config.crashReports && on.issues.isEmpty)
        let bad = try ConfigLoader.parse("[privacy]\nusage_ping = 1\n")
        #expect(!bad.config.usagePing)
        #expect(bad.issues.map(\.message) == ["privacy.usage_ping must be true or false"])
        let edited = try #require(ConfigEditor.set("usage_ping", to: true, in: "privacy", text: DefaultConfig.text))
        let parsed = try ConfigLoader.parse(edited).config
        #expect(parsed.usagePing && !parsed.crashReports)
    }
}
