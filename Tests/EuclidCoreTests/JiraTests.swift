import Foundation
import Testing
@testable import EuclidCore

@Suite struct JiraTests {
    @Test func parsesConfig() throws {
        let c = try ConfigLoader.parse("""
            [jira]
            base_url = "https://acme.atlassian.net/"
            email = "me@acme.com"
            jql = "project = ABC AND resolution = Unresolved"
            recent = false
            refresh_minutes = 10
            """)
        #expect(c.issues.isEmpty, "\(c.issues)")
        let j = try #require(c.config.jira)
        #expect(j.baseURL == "https://acme.atlassian.net")
        #expect(j.isCloud)
        #expect(j.jql == "project = ABC AND resolution = Unresolved")
        #expect(!j.recent)
        #expect(j.refreshMinutes == 10)
        #expect(j.tokenCommand == "security find-generic-password -s euclid-jira -w")
    }

    @Test func needsBaseURLAndCloudEmail() throws {
        let none = try ConfigLoader.parse("[jira]\nemail = \"me@acme.com\"")
        #expect(none.config.jira == nil)
        #expect(none.issues.map(\.message) == [#"jira.base_url is required, e.g. "https://your-site.atlassian.net""#])
        let cloud = try ConfigLoader.parse("[jira]\nbase_url = \"https://acme.atlassian.net\"")
        #expect(cloud.config.jira == nil)
        #expect(cloud.issues.map(\.message) == ["jira.email is required for Jira Cloud (your Atlassian account email)"])
        let dc = try ConfigLoader.parse("[jira]\nbase_url = \"https://jira.acme.com\"")
        #expect(dc.issues.isEmpty)
        #expect(dc.config.jira?.isCloud == false)
        let off = try ConfigLoader.parse("[jira]\nenabled = false\nbase_url = \"http://x\"")
        #expect(off.config.jira == nil)
    }

    @Test func issueKeys() {
        #expect(JiraIssue.key(in: "abc-123") == "ABC-123")
        #expect(JiraIssue.key(in: " PLAT2-9 ") == "PLAT2-9")
        for text in ["ABC-0", "A-1", "ABC 123", "abc-", "1AB-2", "ABC-12x"] { #expect(JiraIssue.key(in: text) == nil, "\(text)") }
    }

    @Test func branchNames() {
        func issue(_ summary: String) -> JiraIssue {
            JiraIssue(kind: .assigned, key: "ABC-7", summary: summary, subtitle: "", url: "", updated: nil)
        }
        #expect(issue("Fix login on Safari (again!)").branchName == "ABC-7-fix-login-on-safari-again")
        #expect(issue("Café crème: résumé").branchName == "ABC-7-cafe-creme-resume")
        #expect(issue("Make the search API cache results between deploys and restarts").branchName == "ABC-7-make-the-search-api-cache-results")
        #expect(issue("!!!").branchName == "ABC-7")
        #expect(JiraIssue.typed("ABC-7", baseURL: "https://j").url == "https://j/browse/ABC-7")
    }

    final class Calls: @unchecked Sendable { var urls: [URL] = [] }

    func client(_ settings: JiraSettings, calls: Calls, status: Int = 200, _ respond: @escaping @Sendable (URL) -> String) -> JiraClient {
        JiraClient(settings: settings, token: "tok") { request in
            calls.urls.append(request.url!)
            return (Data(respond(request.url!).utf8), status)
        }
    }

    static let assignedJSON = #"{"issues":[{"key":"ABC-1","fields":{"summary":"Fix login","status":{"name":"In Progress"},"issuetype":{"name":"Bug"},"project":{"name":"Search"},"updated":"2024-01-01T12:00:00.000+0000"}}]}"#
    static let recentJSON = #"{"issues":[{"key":"ABC-1","fields":{"summary":"Fix login"}},{"key":"XYZ-9","fields":{"summary":"Spec review","status":{"name":"Done"}}}]}"#

    @Test func cloudFetchesAssignedThenRecent() async throws {
        var s = JiraSettings()
        s.baseURL = "https://acme.atlassian.net"
        s.email = "me@acme.com"
        let calls = Calls()
        let items = try await client(s, calls: calls) { url in
            url.query!.contains("issueHistory") ? Self.recentJSON : Self.assignedJSON
        }.fetchAll()
        #expect(items == [
            JiraIssue(kind: .assigned, key: "ABC-1", summary: "Fix login", subtitle: "In Progress · Bug · Search",
                      url: "https://acme.atlassian.net/browse/ABC-1", updated: Date(timeIntervalSince1970: 1_704_110_400)),
            JiraIssue(kind: .recent, key: "XYZ-9", summary: "Spec review", subtitle: "Done",
                      url: "https://acme.atlassian.net/browse/XYZ-9", updated: nil),
        ])
        #expect(calls.urls.map(\.path) == ["/rest/api/3/search/jql", "/rest/api/3/search/jql"])
        let query = try #require(URLComponents(url: calls.urls[0], resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "jql" }?.value == s.jql)
        #expect(!calls.urls[0].absoluteString.contains("+"))
    }

    @Test func dataCenterUsesV2AndSurvivesNoHistory() async throws {
        var s = JiraSettings()
        s.baseURL = "https://jira.acme.com"
        let calls = Calls()
        let items = try await client(s, calls: calls) { url in
            url.query!.contains("issueHistory") ? "not json" : Self.assignedJSON
        }.fetchAll()
        #expect(items.map(\.key) == ["ABC-1"])
        #expect(calls.urls.first?.path == "/rest/api/2/search")
    }

    @Test func badTokenIsAFailure() async {
        var s = JiraSettings()
        s.baseURL = "https://jira.acme.com"
        await #expect(throws: JiraClient.Failure.self) { try await client(s, calls: Calls(), status: 401) { _ in "" }.fetchAll() }
    }
}
