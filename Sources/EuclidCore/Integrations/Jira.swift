import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One Jira issue for search: assigned to you, or one you looked at recently.
public struct JiraIssue: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case assigned   // matches `jql` (default: yours, not done)
        case recent     // you viewed it lately
        case typed      // you typed its key; not fetched
    }
    public let kind: Kind
    /// "ABC-123"
    public let key: String
    public let summary: String
    /// "In Progress · Bug · Search"
    public let subtitle: String
    public let url: String
    public let updated: Date?

    public init(kind: Kind, key: String, summary: String, subtitle: String, url: String, updated: Date?) {
        self.kind = kind
        self.key = key
        self.summary = summary
        self.subtitle = subtitle
        self.url = url
        self.updated = updated
    }

    /// An issue key you typed, opened straight away: `<base>/browse/ABC-123`.
    public static func typed(_ key: String, baseURL: String) -> JiraIssue {
        JiraIssue(kind: .typed, key: key, summary: "Open in Jira", subtitle: "", url: "\(baseURL)/browse/\(key)", updated: nil)
    }

    public var title: String { kind == .typed ? key : "\(key) \(summary)" }

    public func searchItem(id: Int) -> SearchItem {
        SearchItem(id: id, title: title, subtitle: subtitle, date: updated, searchText: "\(key) \(summary) \(subtitle)")
    }

    /// A git branch name: "ABC-123-fix-login-on-safari".
    public var branchName: String {
        guard kind != .typed else { return key }
        var slug = ""
        for c in summary.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) {
            if c.isASCII, c.isLetter || c.isNumber { slug.append(c) }
            else if !slug.isEmpty, slug.last != "-" { slug.append("-") }
        }
        while slug.count > 40, let cut = slug.lastIndex(of: "-") { slug = String(slug[..<cut]) }
        slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? key : "\(key)-\(slug)"
    }

    /// "abc-123" or "ABC-123" → "ABC-123"; nil if the text isn't an issue key.
    public static func key(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.range(of: #"^[A-Za-z][A-Za-z0-9_]+-[1-9][0-9]*$"#, options: .regularExpression) != nil else { return nil }
        return t.uppercased()
    }
}

/// Talks to Jira Cloud (`<site>.atlassian.net`, email + API token) or
/// Data Center (Bearer personal access token). Network goes through `http`, for tests.
public struct JiraClient: Sendable {
    public typealias HTTP = BitbucketClient.HTTP

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    static let fields = "summary,status,issuetype,project,updated"
    static let recentJQL = "issuekey in issueHistory() ORDER BY lastViewed DESC"

    let settings: JiraSettings
    let token: String
    let http: HTTP

    public init(settings: JiraSettings, token: String, http: @escaping HTTP = BitbucketClient.urlSession) {
        self.settings = settings
        self.token = token
        self.http = http
    }

    /// Issues matching `jql`, then recently viewed ones that aren't already in.
    public func fetchAll() async throws -> [JiraIssue] {
        let assigned = issues(try await search(settings.jql, limit: 50), kind: .assigned)
        guard settings.recent else { return assigned }
        // Recently viewed is a nice extra: an old server without issueHistory() shouldn't hide your issues.
        let seen = Set(assigned.map(\.key))
        let recent = ((try? await search(Self.recentJQL, limit: 30)).map { issues($0, kind: .recent) } ?? [])
            .filter { !seen.contains($0.key) }
        return assigned + recent
    }

    func issues(_ page: [String: Any], kind: JiraIssue.Kind) -> [JiraIssue] {
        (page["issues"] as? [[String: Any]] ?? []).compactMap { issue in
            guard let key = issue["key"] as? String, let fields = issue["fields"] as? [String: Any] else { return nil }
            let status = (fields["status"] as? [String: Any])?["name"] as? String
            let type = (fields["issuetype"] as? [String: Any])?["name"] as? String
            let project = (fields["project"] as? [String: Any])?["name"] as? String
            return JiraIssue(kind: kind, key: key, summary: fields["summary"] as? String ?? "",
                             subtitle: [status, type, project].compactMap { $0 }.joined(separator: " · "),
                             url: "\(settings.baseURL)/browse/\(key)",
                             updated: (fields["updated"] as? String).flatMap(Self.parseDate))
        }
    }

    func search(_ jql: String, limit: Int) async throws -> [String: Any] {
        // Cloud retired /rest/api/3/search in 2025 for /search/jql; Data Center still has /rest/api/2/search.
        let path = settings.isCloud ? "/rest/api/3/search/jql" : "/rest/api/2/search"
        var components = URLComponents(string: settings.baseURL + path)
        components?.queryItems = [
            URLQueryItem(name: "jql", value: jql),
            URLQueryItem(name: "fields", value: Self.fields),
            URLQueryItem(name: "maxResults", value: "\(limit)"),
        ]
        // URLComponents leaves "+" alone, which Jira reads as a space.
        let query = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = query
        guard let url = components?.url else { throw Failure(description: "Jira: bad base_url") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if settings.isCloud {
            let basic = Data("\(settings.email):\(token)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, status) = try await http(request)
        switch status {
        case 200..<300: break
        case 400: throw Failure(description: "Jira said 400: check jira.jql")
        case 401, 403: throw Failure(description: "Jira said \(status): check jira.email and the token")
        default: throw Failure(description: "Jira said \(status) for \(path)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "Jira: unexpected response for \(path)")
        }
        return obj
    }

    /// "2024-01-01T12:00:00.000+0000"
    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f.date(from: s)
    }
}
