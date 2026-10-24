import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One searchable thing from Bitbucket: a pull request or a repository.
public struct BitbucketItem: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case myPR        // you opened it
        case reviewPR    // waiting on your review
        case repo
    }
    public let kind: Kind
    public let title: String
    /// "team/repo · #123 · Jane Doe"
    public let subtitle: String
    public let url: String
    public let updated: Date?

    public init(kind: Kind, title: String, subtitle: String, url: String, updated: Date?) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.updated = updated
    }

    public func searchItem(id: Int) -> SearchItem {
        SearchItem(id: id, title: title, subtitle: subtitle, date: updated, searchText: "\(title) \(subtitle)")
    }
}

/// Talks to Bitbucket Cloud (api.bitbucket.org/2.0, email + API token) or
/// Data Center (`<server>/rest/api/1.0`, Bearer HTTP access token).
/// Network goes through `http`, so tests can feed canned responses.
public struct BitbucketClient: Sendable {
    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, Int)

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    let settings: BitbucketSettings
    let token: String
    let http: HTTP

    public init(settings: BitbucketSettings, token: String, http: @escaping HTTP = BitbucketClient.urlSession) {
        self.settings = settings
        self.token = token
        self.http = http
    }

    public static let urlSession: HTTP = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Your open PRs, PRs waiting on your review, and your repos, PRs first.
    public func fetchAll() async throws -> [BitbucketItem] {
        settings.isCloud ? try await fetchCloud() : try await fetchDataCenter()
    }

    // MARK: - Cloud

    func fetchCloud() async throws -> [BitbucketItem] {
        let me = try await json("/user")
        guard let uuid = me["uuid"] as? String else { throw Failure(description: "Bitbucket: /user returned no uuid") }
        let repoJSON = try await json("/repositories?role=member&sort=-updated_on&pagelen=100")
        let repos = Self.cloudRepos(repoJSON)
        let encodedUUID = uuid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? uuid
        let mine = Self.cloudPRs(try await json("/pullrequests/\(encodedUUID)?state=OPEN&pagelen=50"), kind: .myPR)

        // Cloud has no "review requests" endpoint: ask each repo for open PRs with you as reviewer.
        let slugs = settings.repos.isEmpty ? Array(repos.prefix(10).map(\.title)) : settings.repos
        var review: [BitbucketItem] = []
        let q = "state=\"OPEN\" AND reviewers.uuid=\"\(uuid)\""
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? ""
        for slug in slugs {
            guard let page = try? await json("/repositories/\(slug)/pullrequests?q=\(q)&pagelen=50") else { continue }
            review += Self.cloudPRs(page, kind: .reviewPR)
        }
        return review + mine + repos
    }

    static func cloudPRs(_ page: [String: Any], kind: BitbucketItem.Kind) -> [BitbucketItem] {
        (page["values"] as? [[String: Any]] ?? []).compactMap { pr in
            guard let title = pr["title"] as? String, let url = href(pr["links"], "html") else { return nil }
            let repo = ((pr["destination"] as? [String: Any])?["repository"] as? [String: Any])?["full_name"] as? String
            let author = (pr["author"] as? [String: Any])?["display_name"] as? String
            let id = (pr["id"] as? Int).map { "#\($0)" }
            return BitbucketItem(kind: kind, title: title, subtitle: [repo, id, author].compactMap { $0 }.joined(separator: " · "),
                                 url: url, updated: (pr["updated_on"] as? String).flatMap(parseDate))
        }
    }

    static func cloudRepos(_ page: [String: Any]) -> [BitbucketItem] {
        (page["values"] as? [[String: Any]] ?? []).compactMap { r in
            guard let name = r["full_name"] as? String, let url = href(r["links"], "html") else { return nil }
            let description = (r["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Repository"
            return BitbucketItem(kind: .repo, title: name, subtitle: description, url: url,
                                 updated: (r["updated_on"] as? String).flatMap(parseDate))
        }
    }

    // MARK: - Data Center

    func fetchDataCenter() async throws -> [BitbucketItem] {
        let mine = Self.dataCenterPRs(try await json("/rest/api/1.0/dashboard/pull-requests?state=OPEN&role=AUTHOR&limit=50"), kind: .myPR)
        let review = Self.dataCenterPRs(try await json("/rest/api/1.0/dashboard/pull-requests?state=OPEN&role=REVIEWER&limit=50"), kind: .reviewPR)
        let repos = Self.dataCenterRepos((try? await json("/rest/api/1.0/profile/recent/repos?limit=100")) ?? [:])
        return review + mine + repos
    }

    static func dataCenterPRs(_ page: [String: Any], kind: BitbucketItem.Kind) -> [BitbucketItem] {
        (page["values"] as? [[String: Any]] ?? []).compactMap { pr in
            guard let title = pr["title"] as? String, let url = selfHref(pr["links"]) else { return nil }
            let repoJSON = (pr["toRef"] as? [String: Any])?["repository"] as? [String: Any]
            let project = (repoJSON?["project"] as? [String: Any])?["key"] as? String
            let repo = [project, repoJSON?["slug"] as? String].compactMap { $0 }.joined(separator: "/")
            let author = ((pr["author"] as? [String: Any])?["user"] as? [String: Any])?["displayName"] as? String
            let id = (pr["id"] as? Int).map { "#\($0)" }
            let updated = (pr["updatedDate"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return BitbucketItem(kind: kind, title: title, subtitle: [repo.isEmpty ? nil : repo, id, author].compactMap { $0 }.joined(separator: " · "),
                                 url: url, updated: updated)
        }
    }

    static func dataCenterRepos(_ page: [String: Any]) -> [BitbucketItem] {
        (page["values"] as? [[String: Any]] ?? []).compactMap { r in
            guard let slug = r["slug"] as? String, let url = selfHref(r["links"]) else { return nil }
            let project = (r["project"] as? [String: Any])?["key"] as? String
            let name = [project, slug].compactMap { $0 }.joined(separator: "/")
            let description = (r["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Repository"
            return BitbucketItem(kind: .repo, title: name, subtitle: description, url: url, updated: nil)
        }
    }

    // MARK: - Plumbing

    func json(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: settings.baseURL + path) else { throw Failure(description: "Bitbucket: bad URL \(path)") }
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
        case 401, 403: throw Failure(description: "Bitbucket said \(status): check bitbucket.email and the token")
        default: throw Failure(description: "Bitbucket said \(status) for \(path.split(separator: "?").first ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "Bitbucket: unexpected response for \(path)")
        }
        return obj
    }

    /// Cloud: `links.html.href`.
    static func href(_ links: Any?, _ name: String) -> String? {
        ((links as? [String: Any])?[name] as? [String: Any])?["href"] as? String
    }

    /// Data Center: `links.self[0].href`.
    static func selfHref(_ links: Any?) -> String? {
        (((links as? [String: Any])?["self"] as? [[String: Any]])?.first)?["href"] as? String
    }

    static func parseDate(_ s: String) -> Date? {
        // Cloud sends microseconds ("…12:00:00.123456+00:00"); drop them.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }
}
