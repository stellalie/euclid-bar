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
            enabled = true
            limit = 50
            exclude_hosts = ["Mail.Google.com"]

            [obsidian]
            vault = "~/Notes"

            [bitbucket]
            email = "me@example.com"
            repos = ["team/app", "bad"]
            """)
        #expect(c.config.appearance.accent == "#7c5cff")
        #expect(c.config.appearance.density == .compact)
        #expect(!c.config.appearance.glass && !c.config.appearance.showSpeed)
        #expect(c.config.pagesEnabled && c.config.pagesLimit == 50 && c.config.pagesExcludedHosts == ["mail.google.com"])
        #expect(c.config.obsidianVault == "~/Notes")
        #expect(c.config.bitbucket?.repos == ["team/app"])
        #expect(c.issues.count == 1) // the bad repo slug
    }

    @Test func badValuesWarn() throws {
        let c = try ConfigLoader.parse("""
            [appearance]
            accent = "purple"
            density = "huge"

            [bitbucket]
            enabled = true
            """)
        #expect(c.config.appearance == Appearance())
        #expect(c.config.bitbucket == nil) // Cloud needs an email
        #expect(c.issues.count == 3)
    }

    @Test func dataCenterNeedsNoEmail() throws {
        let c = try ConfigLoader.parse("""
            [bitbucket]
            base_url = "https://stash.example.com/"
            """)
        #expect(c.config.bitbucket?.baseURL == "https://stash.example.com")
        #expect(c.config.bitbucket?.isCloud == false)
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
    @Test func pagesSearchWithSnippets() throws {
        let index = try ContentIndex(path: nil)
        try index.savePage(url: "https://a.dev/x", title: "Swift Testing guide", text: "Use #expect to check values in swift-testing.")
        try index.savePage(url: "https://b.dev/y", title: "Other", text: nil)
        let hits = try index.search("expect val")
        #expect(hits.map(\.ref) == ["https://a.dev/x"])
        #expect(hits[0].snippet.contains("expect"))
        #expect(try index.fetchedURLs() == ["https://a.dev/x", "https://b.dev/y"])
        #expect(try index.search("ex").isEmpty)              // too short
        #expect(try index.search(#"a" OR "b"#).isEmpty)      // FTS syntax stays inert
    }

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
        #expect(hits[0].kind == .note)
        try FileManager.default.removeItem(at: vault.appendingPathComponent("Standup.md"))
        try index.syncNotes(vault: vault)
        #expect(try index.search("rollout").isEmpty)
    }

    @Test func fetchPolicy() {
        #expect(PageText.shouldFetch("https://developer.apple.com/documentation/appkit"))
        #expect(!PageText.shouldFetch("https://example.com/reset-password"))
        #expect(!PageText.shouldFetch("https://example.com/page?id=1"))
        #expect(!PageText.shouldFetch("http://localhost:3000/docs"))
        #expect(!PageText.shouldFetch("http://192.168.1.2/docs"))
        #expect(!PageText.shouldFetch("https://mail.google.com/x", excludedHosts: ["google.com"]))
    }

    @Test func extractsVisibleText() {
        let html = """
            <html><head><title>My &amp; Page</title><style>body{}</style></head>
            <body><script>var x = 1;</script><h1>Hello</h1><p>World&nbsp;&#x41;&#66;</p><!-- hidden --></body></html>
            """
        let (title, text) = PageText.extract(html: html)
        #expect(title == "My & Page")
        #expect(text == "Hello\nWorld AB")
    }
}

@Suite struct BitbucketTests {
    final class Calls: @unchecked Sendable { var paths: [String] = []; var auth: [String] = [] }

    func client(_ settings: BitbucketSettings, _ responses: [String: String], calls: Calls) -> BitbucketClient {
        BitbucketClient(settings: settings, token: "tok") { request in
            let url = request.url!.absoluteString
            calls.paths.append(url)
            calls.auth.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            guard let body = responses.first(where: { url.contains($0.key) })?.value else { return (Data(), 404) }
            return (Data(body.utf8), 200)
        }
    }

    @Test func cloud() async throws {
        var s = BitbucketSettings()
        s.email = "me@example.com"
        let calls = Calls()
        let c = client(s, [
            "/user": #"{"uuid":"{abc}"}"#,
            "/repositories?role=member": #"{"values":[{"full_name":"team/app","links":{"html":{"href":"https://bitbucket.org/team/app"}},"updated_on":"2024-01-01T12:00:00.123456+00:00"}]}"#,
            "/pullrequests/%7Babc%7D": #"{"values":[{"id":7,"title":"Fix login","links":{"html":{"href":"https://bitbucket.org/team/app/pull-requests/7"}},"destination":{"repository":{"full_name":"team/app"}},"author":{"display_name":"Me"}}]}"#,
            "/repositories/team/app/pullrequests": #"{"values":[{"id":9,"title":"Add cache","links":{"html":{"href":"https://bitbucket.org/team/app/pull-requests/9"}},"author":{"display_name":"Sam"}}]}"#,
        ], calls: calls)
        let items = try await c.fetchAll()
        #expect(items.map(\.kind) == [.reviewPR, .myPR, .repo])
        #expect(items[1].subtitle == "team/app · #7 · Me")
        #expect(items[2].updated != nil)
        #expect(calls.auth.allSatisfy { $0 == "Basic " + Data("me@example.com:tok".utf8).base64EncodedString() })
    }

    @Test func dataCenter() async throws {
        var s = BitbucketSettings()
        s.baseURL = "https://stash.example.com"
        let calls = Calls()
        let pr = #"{"values":[{"id":3,"title":"Bump deps","updatedDate":1700000000000,"links":{"self":[{"href":"https://stash.example.com/projects/P/repos/r/pull-requests/3"}]},"toRef":{"repository":{"slug":"r","project":{"key":"P"}}},"author":{"user":{"displayName":"Ana"}}}]}"#
        let c = client(s, [
            "role=AUTHOR": #"{"values":[]}"#,
            "role=REVIEWER": pr,
            "recent/repos": #"{"values":[{"slug":"r","project":{"key":"P"},"links":{"self":[{"href":"https://stash.example.com/projects/P/repos/r"}]}}]}"#,
        ], calls: calls)
        let items = try await c.fetchAll()
        #expect(items.map(\.title) == ["Bump deps", "P/r"])
        #expect(items[0].subtitle == "P/r · #3 · Ana")
        #expect(calls.auth.allSatisfy { $0 == "Bearer tok" })
    }

    @Test func authFailureIsReadable() async {
        var s = BitbucketSettings()
        s.baseURL = "https://stash.example.com"
        let c = BitbucketClient(settings: s, token: "x") { _ in (Data(), 401) }
        await #expect(throws: BitbucketClient.Failure.self) { try await c.fetchAll() }
    }
}
