import Foundation
import Testing
@testable import EuclidCore

@Suite struct UsageLogTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }
    func day(_ n: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: n, hour: hour))!
    }

    @Test func receiptCountsTheLastThirtyDays() {
        var log = UsageLog()
        for _ in 0..<3 { log.recordOpen(at: day(24), calendar: calendar) }
        log.recordOpen(at: day(1), calendar: calendar)
        log.recordPick("apps", at: day(24), calendar: calendar)
        log.recordPick("apps", at: day(20), calendar: calendar)
        log.recordPick("actions", at: day(24, hour: 23), calendar: calendar)
        log.recordPick("clips", at: day(1), calendar: calendar)
        let s = log.summary(days: 7, now: day(24, hour: 12), calendar: calendar)
        #expect(s.opens == 3)
        #expect(s.activeDays == 2)
        #expect(s.picks == ["apps": 2, "actions": 1])
        #expect(s.receipt == "3 opens on 2 days · 2 apps, 1 action")
        #expect(log.summary(days: 30, now: day(24), calendar: calendar).receipt == "4 opens on 3 days · 2 apps, 1 action, 1 clip")
    }

    @Test func nothingYetMeansNoReceipt() {
        #expect(UsageLog().summary().receipt == nil)
    }

    @Test func dropsDaysPastNinety() {
        var log = UsageLog()
        let start = day(1)
        for i in 0..<120 { log.recordPick("apps", at: start.addingTimeInterval(Double(i) * 86_400), calendar: calendar) }
        #expect(log.days.count <= UsageLog.keepDays + 1)
        #expect(log.summary(days: 30, now: start.addingTimeInterval(119 * 86_400), calendar: calendar).picks["apps"] == 30)
    }

    @Test func savesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var log = UsageLog()
        log.recordOpen()
        log.recordPick("snippets")
        try log.save(to: url)
        #expect(UsageLog.load(from: url) == log)
        #expect(UsageLog.load(from: url.appendingPathExtension("missing")) == UsageLog())
    }
}
