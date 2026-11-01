import Foundation
import Testing
@testable import EuclidCore

@Suite struct CrashReportTests {
    /// Trimmed from a real macOS 15 crash log of a Swift "Index out of range".
    static let ips = #"""
    {"app_name":"euclid-bar","timestamp":"2026-10-26 09:12:44.00 +1100","app_version":"1.2.1","slice_uuid":"5b1c","build_version":"121","platform":1,"bundleID":"dev.euclid.Euclid","share_with_app_devs":0,"is_first_party":0,"bug_type":"309","os_version":"macOS 15.1 (24B83)","roots_installed":0,"name":"euclid-bar","incident_id":"8F3A"}
    {
      "uptime" : 3600,
      "procName" : "euclid-bar",
      "procPath" : "\/Users\/stella\/Applications\/Euclid.app\/Contents\/MacOS\/euclid-bar",
      "cpuType" : "ARM-64",
      "osVersion" : {"train" : "macOS 15.1", "build" : "24B83", "releaseType" : "User"},
      "exception" : {"codes" : "0x0000000000000001, 0x00000001a2b3c4d5", "type" : "EXC_BREAKPOINT", "signal" : "SIGTRAP"},
      "termination" : {"flags" : 0, "code" : 5, "namespace" : "SIGNAL", "indicator" : "Trace\/BPT trap: 5"},
      "asi" : {"libswiftCore.dylib" : ["Swift\/ContiguousArrayBuffer.swift:691: Fatal error: Index out of range"]},
      "faultingThread" : 0,
      "threads" : [
        {"triggered" : true, "id" : 1, "queue" : "com.apple.main-thread", "frames" : [
          {"imageOffset" : 40000, "symbol" : "_assertionFailure(_:_:file:line:flags:)", "symbolLocation" : 172, "imageIndex" : 1},
          {"imageOffset" : 81234, "symbol" : "LauncherViewController.reload(_:)", "symbolLocation" : 120, "imageIndex" : 0},
          {"imageOffset" : 81500, "symbol" : "closure #1 in PanelController.search(\/Users\/stella\/notes.md)", "symbolLocation" : 64, "imageIndex" : 0},
          {"imageOffset" : 7980, "imageIndex" : 2}
        ]},
        {"id" : 2, "frames" : [{"imageOffset" : 1, "symbol" : "__workq_kernreturn", "symbolLocation" : 8, "imageIndex" : 2}]}
      ],
      "usedImages" : [
        {"source" : "P", "arch" : "arm64", "base" : 4294967296, "name" : "euclid-bar", "path" : "\/Users\/stella\/Applications\/Euclid.app\/Contents\/MacOS\/euclid-bar"},
        {"source" : "P", "arch" : "arm64e", "base" : 6000000000, "name" : "libswiftCore.dylib"},
        {"source" : "P", "arch" : "arm64e", "base" : 7000000000, "name" : "libsystem_kernel.dylib"}
      ]
    }
    """#

    @Test func readsTheCrashedThread() throws {
        let r = try #require(CrashReport.fromIPS(Self.ips, bundleID: "dev.euclid.Euclid", channel: "dev"))
        #expect(r.kind == .crash)
        #expect(r.title == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(r.message == "Swift/ContiguousArrayBuffer.swift:691: Fatal error: Index out of range")
        #expect(r.frames == [
            "libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:) + 172",
            "euclid-bar  LauncherViewController.reload(_:) + 120",
            "euclid-bar  closure #1 in PanelController.search(~/notes.md) + 64",
            "libsystem_kernel.dylib  +0x1f2c",
        ])
        #expect(r.app == "1.2.1" && r.build == "121" && r.channel == "dev")
        #expect(r.os == "macOS 15.1 (24B83)" && r.arch == "arm64")
        #expect(r.fingerprint.count == 12)
    }

    @Test func skipsOtherAppsAndJunk() {
        #expect(CrashReport.fromIPS(Self.ips, bundleID: "com.other.App", channel: "stable") == nil)
        #expect(CrashReport.fromIPS("not a crash log", bundleID: "dev.euclid.Euclid", channel: "stable") == nil)
        #expect(CrashReport.fromIPS("{}\n{", bundleID: "dev.euclid.Euclid", channel: "stable") == nil)
    }

    @Test func uncaughtExceptionUsesItsBacktrace() throws {
        let withException = Self.ips.replacingOccurrences(of: #""faultingThread" : 0,"#, with: #"""
            "faultingThread" : 0,
            "lastExceptionBacktrace" : [{"imageOffset" : 5, "symbol" : "-[NSArray objectAtIndex:]", "symbolLocation" : 4, "imageIndex" : 0}],
            """#)
        let r = try #require(CrashReport.fromIPS(withException, bundleID: "dev.euclid.Euclid", channel: "stable"))
        #expect(r.frames == ["euclid-bar  -[NSArray objectAtIndex:] + 4"])
    }

    @Test func sameBugSameFingerprintAcrossBuilds() throws {
        let a = try #require(CrashReport.fromIPS(Self.ips, bundleID: "dev.euclid.Euclid", channel: "dev"))
        let moved = Self.ips.replacingOccurrences(of: #""symbolLocation" : 120"#, with: #""symbolLocation" : 132"#)
            .replacingOccurrences(of: "1.2.1", with: "1.2.2")
        let b = try #require(CrashReport.fromIPS(moved, bundleID: "dev.euclid.Euclid", channel: "stable"))
        #expect(a.fingerprint == b.fingerprint)

        let other = Self.ips.replacingOccurrences(of: "LauncherViewController.reload", with: "Row.draw")
        #expect(try #require(CrashReport.fromIPS(other, bundleID: "dev.euclid.Euclid", channel: "dev")).fingerprint != a.fingerprint)
    }

    @Test func errorsAreScrubbedAndGroupedByMessage() {
        func error(_ m: String) -> CrashReport {
            CrashReport(kind: .error, title: "clipboard", message: m, app: "1.2.1", build: "121", channel: "stable", os: "macOS 15.1", arch: "arm64")
        }
        let r = error("history store unavailable: SQLite error 14: unable to open /Users/stella/Library/clips.sqlite for me@example.com")
        #expect(r.message == "history store unavailable: SQLite error 14: unable to open ~/Library/clips.sqlite for <email>")
        #expect(r.fingerprint == error("history store unavailable: SQLite error 26: unable to open /Users/bob/Library/clips.sqlite for me@example.com").fingerprint)
        #expect(error(String(repeating: "x", count: 5_000)).message.count == 1_001)
    }

    @Test func jsonIsWhatTheServerReads() throws {
        let r = try #require(CrashReport.fromIPS(Self.ips, bundleID: "dev.euclid.Euclid", channel: "dev"))
        let object = try #require(try JSONSerialization.jsonObject(with: r.json()) as? [String: Any])
        #expect(Set(object.keys) == ["kind", "title", "message", "frames", "app", "build", "channel", "os", "arch", "fingerprint"])
        #expect(object["kind"] as? String == "crash")
    }

    @Test func offByDefaultAndParsed() throws {
        #expect(!EuclidConfig().crashReports)
        #expect(!(try ConfigLoader.parse(DefaultConfig.text).config.crashReports))
        let on = try ConfigLoader.parse("[privacy]\ncrash_reports = true\n")
        #expect(on.config.crashReports && on.issues.isEmpty)
        let bad = try ConfigLoader.parse("[privacy]\ncrash_reports = \"yes\"\ntelemetry = true\n")
        #expect(!bad.config.crashReports)
        #expect(bad.issues.map(\.message) == ["[privacy]: unknown key 'telemetry'", "privacy.crash_reports must be true or false"])
        let edited = try #require(ConfigEditor.set("crash_reports", to: true, in: "privacy", text: DefaultConfig.text))
        #expect(try ConfigLoader.parse(edited).config.crashReports)
    }
}
