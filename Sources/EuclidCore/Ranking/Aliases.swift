/// Short keywords that jump to one result: `gh` → "Search GitHub", `code` → "Visual Studio Code".
///
/// An exact alias puts its target first. For an action, `alias rest of query`
/// runs the action on "rest of query" (`gh swift testing` searches GitHub).
public struct Aliases: Equatable, Sendable {
    /// alias (lowercased) → target title (an app, project or action name).
    public private(set) var targets: [String: String] = [:]

    public init(_ targets: [String: String] = [:]) {
        for (alias, target) in targets { add(alias, target: target) }
    }

    public mutating func add(_ alias: String, target: String) {
        let a = alias.trimmingCharacters(in: .whitespaces).lowercased()
        guard !a.isEmpty, !a.contains(" ") else { return }
        targets[a] = target
    }

    public struct Match: Equatable, Sendable {
        public let target: String
        /// Text after "alias ", or nil when the whole query is the alias.
        public let argument: String?
    }

    public func match(_ query: String) -> Match? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if let t = targets[q.lowercased()] { return Match(target: t, argument: nil) }
        guard let space = q.firstIndex(of: " ") else { return nil }
        let head = q[..<space].lowercased()
        let rest = q[space...].trimmingCharacters(in: .whitespaces)
        guard let t = targets[head], !rest.isEmpty else { return nil }
        return Match(target: t, argument: rest)
    }

    /// Alias shown next to a title in the list, if any.
    public func alias(for title: String) -> String? {
        targets.filter { $0.value == title }.keys.min()
    }
}
