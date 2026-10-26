import Foundation
import Testing
@testable import EuclidCore

/// The bitbucket and jira example plugins, run for real against a fake `curl` that answers
/// from canned responses (matched by URL substring) and logs every call.
@Suite struct AtlassianPluginTests {
    struct Run {
        let items: [PluginItem]
        let calls: [String]
    }

    func run(_ example: String, script: String = "./items.sh", query: String = "", settings: [String: String],
             responses: [String: String], status: Int = 200, extraEnv: [String: String] = [:]) async throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-atl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try PluginGuide.installExample(example, in: dir.appendingPathComponent("plugins"))
        let bin = dir.appendingPathComponent("bin"), fixtures = dir.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        for (i, (pattern, body)) in responses.sorted(by: { $0.key < $1.key }).enumerated() {
            try "\(pattern)\n\(body)".write(to: fixtures.appendingPathComponent("r\(i)"), atomically: true, encoding: .utf8)
        }
        let curl = bin.appendingPathComponent("curl")
        try """
            #!/bin/sh
            for a in "$@"; do url=$a; done
            printf '%s\\n' "$*" >> "\(dir.path)/calls"
            for f in "\(fixtures.path)"/r*; do
              [ -f "$f" ] || continue
              pat=$(head -n 1 "$f")
              case $url in *"$pat"*) tail -n +2 "$f"; printf '\\n\(status)'; exit 0 ;; esac
            done
            printf '\\n404'
            """.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)

        var issues: [ConfigIssue] = []
        let text = try String(contentsOf: folder.appendingPathComponent("plugin.toml"), encoding: .utf8)
        var plugin = try #require(PluginLoader.parse(text, id: example, directory: folder.path, &issues))
        plugin.settings.merge(settings) { $1 }
        let out = try await PluginRunner.output(of: script, plugin: plugin, query: query, shell: "/bin/zsh", pathPrefix: bin.path,
                                                environment: ProcessInfo.processInfo.environment.merging(extraEnv) { $1 },
                                                timeout: .seconds(20))
        let calls = (try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return Run(items: PluginOutput.parse(out).items, calls: calls)
    }

    // MARK: - Bitbucket

    @Test func bitbucketCloud() async throws {
        let r = try await run("bitbucket", settings: ["email": "me@example.com", "token_command": "echo tok"], responses: [
            "/user": #"{"uuid":"{abc}"}"#,
            "/repositories?role=member": #"{"values":[{"full_name":"team/app","links":{"html":{"href":"https://bitbucket.org/team/app"}}}]}"#,
            "/pullrequests/%7Babc%7D": #"{"values":[{"id":7,"title":"Fix login","links":{"html":{"href":"https://bitbucket.org/team/app/pull-requests/7"}},"destination":{"repository":{"full_name":"team/app"}},"author":{"display_name":"Me"}}]}"#,
            "/repositories/team/app/pullrequests": #"{"values":[{"id":9,"title":"Add cache","links":{"html":{"href":"https://bitbucket.org/team/app/pull-requests/9"}},"author":{"display_name":"Sam"}}]}"#,
        ])
        #expect(r.items.map(\.title) == ["Add cache", "Fix login", "team/app"])
        #expect(r.items.map(\.label) == ["Review", "Your PR", "Repo"])
        #expect(r.items[0].suggest == true) // waiting on your review: on the empty bar too
        #expect(r.items[1].subtitle == "team/app · #7 · Me")
        #expect(r.items[2].subtitle == "Repository")
        #expect(r.calls.allSatisfy { $0.contains("-u me@example.com:tok") })
        #expect(r.calls.last?.contains("reviewers.uuid") == true)
    }

    @Test func bitbucketDataCenter() async throws {
        let pr = #"{"values":[{"id":3,"title":"Bump deps","links":{"self":[{"href":"https://stash.example.com/projects/P/repos/r/pull-requests/3"}]},"toRef":{"repository":{"slug":"r","project":{"key":"P"}}},"author":{"user":{"displayName":"Ana"}}}]}"#
        let r = try await run("bitbucket", settings: ["base_url": "https://stash.example.com/", "token_command": "echo tok"], responses: [
            "role=AUTHOR": #"{"values":[]}"#,
            "role=REVIEWER": pr,
            "recent/repos": #"{"values":[{"slug":"r","project":{"key":"P"},"links":{"self":[{"href":"https://stash.example.com/projects/P/repos/r"}]}}]}"#,
        ])
        #expect(r.items.map(\.title) == ["Bump deps", "P/r"])
        #expect(r.items[0].subtitle == "P/r · #3 · Ana")
        #expect(r.calls.allSatisfy { $0.contains("Authorization: Bearer tok") && $0.contains("https://stash.example.com/rest/") })
    }

    @Test func bitbucketSaysWhatIsWrong() async throws {
        await #expect(throws: PluginRunner.Failure.self) {
            try await run("bitbucket", settings: ["token_command": "echo tok"], responses: [:]) // Cloud, no email
        }
        do {
            _ = try await run("bitbucket", settings: ["base_url": "https://stash.example.com", "token_command": "echo tok"],
                              responses: ["/rest/": "{}"], status: 401)
            Issue.record("a 401 should fail")
        } catch let failure as PluginRunner.Failure {
            #expect(failure.description.contains("Bitbucket said 401: check the email and token"))
        }
    }

    // MARK: - Jira

    static let assignedJSON = #"{"issues":[{"key":"ABC-1","fields":{"summary":"Fix login","status":{"name":"In Progress"},"issuetype":{"name":"Bug"},"project":{"name":"Search"}}}]}"#
    static let recentJSON = #"{"issues":[{"key":"ABC-1","fields":{"summary":"Fix login"}},{"key":"XYZ-9","fields":{"summary":"Spec review","status":{"name":"Done"}}}]}"#

    @Test func jiraCloudAssignedThenRecent() async throws {
        let r = try await run("jira", settings: ["base_url": "https://acme.atlassian.net", "email": "me@acme.com", "token_command": "echo tok"],
                              responses: ["issueHistory": Self.recentJSON, "statusCategory": Self.assignedJSON])
        #expect(r.items.map(\.title) == ["ABC-1 Fix login", "XYZ-9 Spec review"])
        #expect(r.items[0].subtitle == "In Progress · Bug · Search")
        #expect(r.items[0].open == "https://acme.atlassian.net/browse/ABC-1")
        #expect(r.items[0].copy == "ABC-1") // ⌘C copies the key
        #expect(r.items[0].suggest == true && r.items[1].suggest == nil)
        #expect(r.items[1].label == "Viewed")
        #expect(r.calls.allSatisfy { $0.contains("/rest/api/3/search/jql?jql=") && $0.contains("Authorization: Basic " + Data("me@acme.com:tok".utf8).base64EncodedString()) })
        #expect(!r.calls[0].contains("+")) // "+" would read as a space
    }

    @Test func jiraDataCenterSurvivesNoHistory() async throws {
        let r = try await run("jira", settings: ["base_url": "https://jira.acme.com", "token_command": "echo tok"],
                              responses: ["issueHistory": "not json", "statusCategory": Self.assignedJSON])
        #expect(r.items.map(\.title) == ["ABC-1 Fix login"])
        #expect(r.calls.first?.contains("https://jira.acme.com/rest/api/2/search?") == true)
        #expect(r.calls.first?.contains("Authorization: Bearer tok") == true)
    }

    @Test func jiraTypedKeyOpensWithoutTheNetwork() async throws {
        let r = try await run("jira", script: "./open.sh", query: "abc-12", settings: ["base_url": "https://acme.atlassian.net/"], responses: [:])
        #expect(r.items.map(\.title) == ["ABC-12"])
        #expect(r.items.first?.open == "https://acme.atlassian.net/browse/ABC-12")
        #expect(r.calls.isEmpty)
        var issues: [ConfigIssue] = []
        let answer = try #require(PluginLoader.parse(PluginGuide.jiraManifest, id: "jira", directory: "/x", &issues)?.answer)
        #expect(answer.input(for: "PLAT2-9") == "PLAT2-9")
        for text in ["ABC-0", "A-1", "ABC 123", "abc-", "1AB-2", "ABC-12x", "12 * 3"] { #expect(answer.input(for: text) == nil, "\(text)") }
    }

    @Test(arguments: [
        ("ABC-7 Fix login on Safari (again!)", "ABC-7-fix-login-on-safari-again"),
        ("ABC-7 Café crème: résumé", "ABC-7-cafe-creme-resume"),
        ("ABC-7 Make the search API cache results between deploys and restarts", "ABC-7-make-the-search-api-cache-results"),
        ("ABC-7 !!!", "ABC-7"),
        ("ABC-7", "ABC-7"),
    ])
    func jiraBranchNames(title: String, branch: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-br-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try PluginGuide.installExample("jira", in: dir)
        var issues: [ConfigIssue] = []
        let text = try String(contentsOf: folder.appendingPathComponent("plugin.toml"), encoding: .utf8)
        let plugin = try #require(PluginLoader.parse(text, id: "jira", directory: folder.path, &issues))
        #expect(plugin.keys.map(\.key.symbols) == ["⇧⌘C"])
        let out = try await PluginRunner.output(of: "./branch.sh", plugin: plugin, shell: "/bin/zsh", pathPrefix: nil,
                                                environment: ProcessInfo.processInfo.environment.merging(["EUCLID_ITEM_TITLE": title]) { $1 },
                                                timeout: .seconds(10))
        #expect(PluginEffect.parse(out).first?.copy == branch)
    }
}
