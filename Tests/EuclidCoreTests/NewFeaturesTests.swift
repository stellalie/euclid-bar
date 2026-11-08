import Foundation
import Testing
@testable import EuclidCore

@Suite struct MatchRangesTests {
    private func marked(_ q: String, _ t: String) -> String {
        var out = t
        for r in FuzzyMatcher.matchRanges(query: q, in: t).reversed() {
            out.replaceSubrange(r, with: "[\(t[r])]")
        }
        return out
    }

    @Test func prefersWordStartSubstring() {
        #expect(marked("base", "database rebase base") == "database rebase [base]")
        #expect(marked("REB", "git rebase") == "git [reb]ase")
    }

    @Test func fallsBackToFirstSubstringThenSubsequence() {
        #expect(marked("ase", "database") == "datab[ase]")
        #expect(marked("gtrb", "git rebase") == "[g]i[t] [r]e[b]ase")
        #expect(marked("zz", "git").isEmpty == false)
        #expect(FuzzyMatcher.matchRanges(query: "zz", in: "git").isEmpty)
    }

    @Test func displayRangesDropStrayLetters() {
        func shown(_ q: String, _ t: String) -> String {
            var out = t
            for r in FuzzyMatcher.displayRanges(query: q, in: t).reversed() { out.replaceSubrange(r, with: "[\(t[r])]") }
            return out
        }
        #expect(shown("gtrb", "git rebase") == "[g]it [r]ebase") // word starts stay, mid-word singles go
        #expect(shown("reba", "git rebase") == "git [reba]se") // contiguous: unchanged
        #expect(shown("dock", "do a check") == "[do] a [c]heck")
    }

    @Test func foldsAccentsAndKeepsRangesValid() {
        #expect(marked("cafe", "Café au lait") == "[Café] au lait")
        #expect(marked("ok", "👍 ok") == "👍 [ok]")
    }
}

@Suite struct DevTransformsTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func epochBothWays() throws {
        let r = DevTransforms.evaluate("1697040000", timeZone: utc)
        #expect(r.first?.value == "2023-10-11 16:00:00 Z")
        #expect(DevTransforms.evaluate("1697040000000", timeZone: utc).first?.label == "Epoch ms → Date")
        #expect(DevTransforms.evaluate("2023-10-11T16:00:00Z").first?.value == "1697040000")
        #expect(DevTransforms.evaluate("12345", timeZone: utc).isEmpty)       // not an epoch
        #expect(DevTransforms.evaluate("9999999999", timeZone: utc).isEmpty)  // year 2286
    }

    @Test func uuidAndNow() {
        let u = DevTransforms.evaluate("uuid")
        #expect(u.count == 1 && UUID(uuidString: u[0].value) != nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(DevTransforms.evaluate("now", now: now, timeZone: utc).first?.value == "1700000000")
    }

    @Test func base64() {
        #expect(DevTransforms.evaluate("b64 hello world").first?.value == "aGVsbG8gd29ybGQ=")
        #expect(DevTransforms.evaluate("aGVsbG8gd29ybGQ=").first?.value == "hello world")
        #expect(DevTransforms.evaluate("b64d aGVsbG8").first?.value == "hello")
        #expect(DevTransforms.evaluate("kubernetes").isEmpty)     // plain words never decode
        #expect(DevTransforms.evaluate("abcdefghijklmnop").isEmpty)
    }

    @Test func base64LeavesLookalikesAlone() {
        let lookalikes = [
            "3f786850e387550fdab836ed7e6dc881de23001b",       // git SHA
            "d41d8cd98f00b204e9800998ecf8427e",               // md5
            "9b2f3c4e5a6d7e8f9a0b1c2d3e4f5a6b",               // uuid without dashes
            "/opt/homebrew/bin/python3",                      // path
            "ThisIsAVeryLongCamelCaseName",                   // identifier
            "node_modules_cache_v2",                          // identifier
            "release-2026-10-25-build",                       // branch name
            "useEffectCleanup2024",                           // identifier
            "AbCdEfGhIjKlMnOpQrStUvWx",                       // decodes to gibberish
        ]
        for s in lookalikes {
            #expect(DevTransforms.autoBase64(s).isEmpty, "\(s) decoded to \(DevTransforms.autoBase64(s).first?.value ?? "")")
        }
        // Real payloads still decode: padded, unpadded, URL-safe, JSON.
        let token = Data(#"{"user":"stella","id":42}"#.utf8).base64EncodedString()
        #expect(DevTransforms.autoBase64(token).first?.value == #"{"user":"stella","id":42}"#)
        let urlSafe = Data("subjects?/a>b".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(DevTransforms.autoBase64(urlSafe).first?.value == "subjects?/a>b")
        #expect(DevTransforms.autoBase64("dXNlcm5hbWU6cGFzc3dvcmQ=").first?.value == "username:password")
    }

    @Test func json() {
        let r = DevTransforms.evaluate(#"{"b":1,"a":[1,2]}"#)
        #expect(r.count == 2)
        #expect(r[0].value.contains("\n"))
        #expect(r[1].value == #"{"a":[1,2],"b":1}"#)
        #expect(DevTransforms.evaluate("{not json").isEmpty)
    }

    @Test func urlAndColor() {
        #expect(DevTransforms.evaluate("a%20b%2Fc").first?.value == "a b/c")
        #expect(DevTransforms.evaluate("urlencode a b&c").first?.value == "a%20b%26c")
        let hex = DevTransforms.evaluate("#ff8800")
        #expect(hex.first?.value == "rgb(255, 136, 0)")
        #expect(hex.first?.color?.r == 1)
        #expect(DevTransforms.evaluate("rgb(255, 136, 0)").first?.value == "#ff8800")
        #expect(DevTransforms.evaluate("#fff").first?.value == "rgb(255, 255, 255)")
        #expect(DevTransforms.evaluate("#zzz").isEmpty)
    }

    @Test func jwt() {
        let header = Data(#"{"alg":"HS256"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let payload = Data(#"{"sub":"42","exp":1}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let r = DevTransforms.evaluate("\(header).\(payload).sig")
        #expect(r.first?.label == "JWT decode")
        #expect(r.first?.display.contains("sub 42") == true)
        #expect(r.first?.display.contains("expired") == true)
        #expect(r.first?.value.contains(#""alg" : "HS256""#) == true)
    }
}

@Suite struct SnippetTests {
    @Test func expandsPlaceholders() {
        let s = Snippet(name: "sig", text: "On {date} at {time}: {clipboard} {nope}")
        let now = Date(timeIntervalSince1970: 1_697_040_000)
        let out = s.expanded(now: now, clipboard: { "clip" }, timeZone: TimeZone(identifier: "UTC")!)
        #expect(out == "On 2023-10-11 at 16:00: clip {nope}")
    }

    @Test func parsesFromConfig() throws {
        let c = try ConfigLoader.parse("""
            [[snippet]]
            name = "Signature"
            keyword = "sig"
            text = "Cheers"

            [[snippet]]
            name = "Broken"
            """)
        #expect(c.config.snippets == [Snippet(name: "Signature", keyword: "sig", text: "Cheers")])
        #expect(c.issues.count == 1)
    }
}

@Suite struct NewConfigTests {
    @Test func appearanceAndSources() throws {
        let c = try ConfigLoader.parse("""
            [appearance]
            accent = "#7c5cff"
            density = "compact"
            glass = false
            show_speed = false

            [pages]
            enabled = false
            limit = 500

            [obsidian]
            vault = "~/Notes"
            """)
        #expect(c.config.appearance.accent == "#7c5cff")
        #expect(c.config.appearance.density == .compact)
        #expect(!c.config.appearance.glass && !c.config.appearance.showSpeed)
        #expect(c.config.obsidianVault == "~/Notes")
        #expect(c.issues.isEmpty) // the old, off [pages] table is ignored quietly
    }

    @Test func removedPagesTableSaysSoOnlyWhenOn() throws {
        let c = try ConfigLoader.parse("[pages]\nenabled = true")
        #expect(c.issues.map(\.message) == ["[pages] was removed: Euclid no longer downloads pages. Delete the table; browser history still works"])
    }

    @Test func badValuesWarn() throws {
        let c = try ConfigLoader.parse("""
            [appearance]
            accent = "purple"
            density = "huge"
            """)
        #expect(c.config.appearance == Appearance())
        #expect(c.issues.count == 2)
    }

    @Test func defaultConfigStillClean() throws {
        #expect(try ConfigLoader.parse(DefaultConfig.text).issues.isEmpty)
    }
}

@Suite struct ClipKindTests {
    @Test func imagesAndFilesPersistAndDedupe() throws {
        let store = try ClipStore(path: nil)
        let h = ClipHistory()
        let now = Date()
        try store.applySync(#require(h.record("abc.png", kind: .image, meta: "10×20", sourceBundleID: nil, sourceName: "Preview", at: now)))
        try store.applySync(#require(h.record("/tmp/a.txt\n/tmp/b.txt", kind: .files, sourceBundleID: nil, sourceName: "Finder", at: now)))
        // The same text as a text clip is a different clip.
        try store.applySync(#require(h.record("abc.png", sourceBundleID: nil, sourceName: nil, at: now)))
        #expect(h.count == 3)
        #expect(h.record("abc.png", kind: .image, sourceBundleID: nil, sourceName: nil, at: now)?.saved?.kind == .image)
        #expect(h.count == 3)

        let loaded = try store.loadRecent(limit: 10)
        let image = try #require(loaded.first { $0.kind == .image })
        #expect(image.meta == "10×20")
        let files = try #require(loaded.first { $0.kind == .files })
        #expect(files.paths == ["/tmp/a.txt", "/tmp/b.txt"])
        #expect(files.searchItem.title == "2 files: a.txt, b.txt")
        #expect(image.searchItem.title == "Image · 10×20")
    }
}

@Suite struct ContentIndexTests {
    @Test func notesFollowTheVault() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "Meeting about rollout plans".write(to: vault.appendingPathComponent("Standup.md"), atomically: true, encoding: .utf8)
        try "rollout secret".write(to: vault.appendingPathComponent(".obsidian/cache.md"), atomically: true, encoding: .utf8)
        let index = try ContentIndex(path: nil)
        #expect(try index.syncNotes(vault: vault) == 1)
        #expect(try index.syncNotes(vault: vault) == 0) // unchanged
        let hits = try index.search("rollout")
        #expect(hits.map(\.title) == ["Standup"])
        #expect(hits[0].snippet.contains("rollout"))
        #expect(try index.search("ro").isEmpty)                // too short
        #expect(try index.search(#"a" OR "b"#).isEmpty)        // FTS syntax stays inert
        try FileManager.default.removeItem(at: vault.appendingPathComponent("Standup.md"))
        try index.syncNotes(vault: vault)
        #expect(try index.search("rollout").isEmpty)
    }
}
