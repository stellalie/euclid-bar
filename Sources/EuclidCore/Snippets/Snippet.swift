import Foundation

/// A saved piece of text from `[[snippet]]` in config.toml. Search finds it by name
/// or keyword; ↵ pastes it, with placeholders filled in:
///
///     {date} 2026-10-18   {time} 14:05   {datetime} 2026-10-18 14:05
///     {clipboard} what's on the clipboard now   {uuid} a fresh UUID
public struct Snippet: Equatable, Sendable {
    public let name: String
    /// Typing exactly this pins the snippet first, e.g. "sig".
    public let keyword: String?
    public let text: String

    public init(name: String, keyword: String? = nil, text: String) {
        self.name = name
        self.keyword = keyword
        self.text = text
    }

    public func searchItem(id: Int) -> SearchItem {
        SearchItem(id: id, title: name, subtitle: keyword ?? "", searchText: [name, keyword ?? ""].joined(separator: " "))
    }

    public func expanded(now: Date = Date(), clipboard: () -> String? = { nil }, timeZone: TimeZone = .current) -> String {
        guard text.contains("{") else { return text }
        func format(_ f: String) -> String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = timeZone
            df.dateFormat = f
            return df.string(from: now)
        }
        var out = text
        for token in ["{datetime}", "{date}", "{time}", "{uuid}", "{clipboard}"] where out.contains(token) {
            let value = switch token {
            case "{datetime}": format("yyyy-MM-dd HH:mm")
            case "{date}": format("yyyy-MM-dd")
            case "{time}": format("HH:mm")
            case "{uuid}": UUID().uuidString.lowercased()
            default: clipboard() ?? ""
            }
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }
}
