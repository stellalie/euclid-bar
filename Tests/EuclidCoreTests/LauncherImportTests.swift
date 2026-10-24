import Foundation
import Testing
@testable import EuclidCore

@Suite struct LauncherImportTests {
    func importing(_ files: [(String, String)], existing: Set<String> = []) -> LauncherImport.Result {
        var result = LauncherImport.Result()
        for (name, json) in files { LauncherImport.parse(Data(json.utf8), fileName: name, into: &result, existing: existing) }
        return result
    }

    @Test func raycastSnippetsAndQuicklinks() throws {
        let r = importing([
            ("snippets.json", #"""
            [{"name":"Sig","text":"Cheers,\n{cursor}Stella","keyword":"!sig"},
             {"name":"Stamp","text":"Shipped {date format=\"yyyy-MM-dd\"} at {time} from {clipboard offset=1}","keyword":"two words"}]
            """#),
            ("quicklinks.json", #"""
            [{"name":"Jira search","link":"https://jira.example.com/issues/?jql=text~\"{argument name=\"q\"}\""},
             {"name":"Dashboard","link":"https://grafana.example.com/d/$abc"},
             {"name":"Notes folder","link":"~/Notes"}]
            """#),
        ])
        #expect(r.snippets == [
            Snippet(name: "Sig", keyword: "!sig", text: "Cheers,\nStella"),
            Snippet(name: "Stamp", keyword: nil, text: "Shipped {date} at {time} from {clipboard}"),
        ])
        #expect(r.quicklinks.map(\.run) == [
            #"open "https://jira.example.com/issues/?jql=text~\"$EUCLID_QUERY_URL\"""#,
            #"open "https://grafana.example.com/d/\$abc""#,
        ])
        #expect(r.skipped == ["Notes folder: only web links can be imported (~/Notes)"])
    }

    @Test func alfredSnippetFiles() {
        let r = importing([("a.json", #"{"alfredsnippet":{"snippet":"{date:short} {random:UUID}","uid":"1","name":"Log line","keyword":"ll"}}"#)])
        #expect(r.snippets == [Snippet(name: "Log line", keyword: "ll", text: "{date} {uuid}")])
    }

    @Test func skipsWhatYouAlreadyHaveAndJunk() {
        let r = importing([
            ("s.json", #"[{"name":"Search web","text":"x"},{"name":"","text":"x"},{"name":"Odd"}]"#),
            ("bad.json", "not json"),
        ], existing: ["Search web"])
        #expect(r.isEmpty)
        #expect(r.skipped == ["Search web: already in your config", "s.json: an entry without a name",
                              "Odd: neither a snippet nor a quicklink", "bad.json: not a JSON export"])
    }

    /// What we write must read back as the same snippets and actions, and run safely.
    @Test func tomlRoundTripsThroughTheConfigLoader() throws {
        let r = importing([
            ("s.json", #"[{"name":"Tricky \"quotes\"","text":"line 1\n\"\"\" not the end \\ backslash\n\ttab","keyword":"tq"}]"#),
            ("q.json", #"[{"name":"Search docs","link":"https://docs.example.com/?q={query}&x=`id`"}]"#),
        ])
        let loaded = try ConfigLoader.parse(DefaultConfig.text + LauncherImport.toml(r, source: "Raycast"))
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.config.snippets.last == r.snippets[0])
        #expect(loaded.config.actions.last == Action(name: "Search docs", run: r.quicklinks[0].run))
    }

    @Test func importedQuicklinkKeepsTheQueryInert() async throws {
        let r = importing([("q.json", #"[{"name":"S","link":"https://example.com/?q={argument}&a=$(echo hi)"}]"#)])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        // Same shell line as `open`, but echo the URL to a file.
        let run = r.quicklinks[0].run.replacingOccurrences(of: "open ", with: "printf %s ") + " > '\(out.path)'"
        let result = await withCheckedContinuation { c in
            CommandRunner.runInBackground(shell: "/bin/zsh", command: run, query: "a b") { c.resume(returning: $0) }
        }
        guard case .success = result else { Issue.record("\(result)"); return }
        #expect(try String(contentsOf: out, encoding: .utf8) == "https://example.com/?q=a%20b&a=$(echo hi)")
    }
}
