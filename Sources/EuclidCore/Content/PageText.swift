import Foundation

/// Which visited pages are safe to download for the content index, and how to
/// turn their HTML into searchable text.
public enum PageText {
    /// Words in a URL that suggest a one-time or account link: fetching it again
    /// could use up a token or change something. Never fetched.
    static let sensitiveWords = ["login", "logout", "signin", "sign-in", "signout", "auth", "oauth", "token", "reset",
                                 "verify", "confirm", "unsubscribe", "callback", "password", "invite", "magic", "checkout",
                                 "payment", "billing", "account", "session", "delete", "download"]

    /// Only plain public http(s) pages: no query string with keys, no localhost or
    /// private hosts, no sensitive-looking paths, nothing in `excludedHosts`.
    public static func shouldFetch(_ urlString: String, excludedHosts: [String] = []) -> Bool {
        guard let c = URLComponents(string: urlString), let scheme = c.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = c.host?.lowercased(), host.contains(".") else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".test") { return false }
        if host.range(of: #"^(\d+\.){3}\d+$"#, options: .regularExpression) != nil { return false } // raw IPs
        if excludedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        if let items = c.queryItems, !items.isEmpty { return false }
        let lower = urlString.lowercased()
        return !sensitiveWords.contains { lower.contains($0) }
    }

    /// Visible text of an HTML page (scripts, styles and tags dropped, entities decoded,
    /// whitespace collapsed), capped at `limit` characters, plus its <title>.
    public static func extract(html: String, limit: Int = 20_000) -> (title: String, text: String) {
        var s = html
        let title = firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: s).map(decodeEntities)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for pattern in [#"<(script|style|noscript|svg|template|head)\b[\s\S]*?</\1>"#, #"<!--[\s\S]*?-->"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"<(br|p|div|li|h[1-6]|tr|section|article)\b[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        return (title, String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)))
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                               ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&copy;", "©")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        if let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10)
                result += n.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: m.range)
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
