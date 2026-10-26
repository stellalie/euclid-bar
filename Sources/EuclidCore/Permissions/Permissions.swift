import Foundation

/// The macOS permissions Euclid uses, in one list: what each one is for, whether something you
/// turned on is waiting for it, and the System Settings pane that grants it. Shown by the
/// "Permissions" row (type "permissions"); the footer only names it when a need is required.
public enum Permissions {
    public enum Kind: String, Sendable { case accessibility, fullDiskAccess }

    public struct Need: Equatable, Sendable {
        public let kind: Kind
        public let title: String
        /// What stops working without it.
        public let why: String
        /// Something you turned on is waiting for it (vs. a feature you might want).
        public let required: Bool
        public var pane: URL { Permissions.pane(kind) }
    }

    /// What the app knows right now.
    public struct State: Equatable, Sendable {
        public var accessibility: Bool
        public var expansionEnabled: Bool
        /// Safari's history file was found but couldn't be read (no Full Disk Access).
        public var safariBlocked: Bool
        /// `[history] browsers` names Safari, so you asked for it.
        public var safariRequested: Bool

        public init(accessibility: Bool, expansionEnabled: Bool, safariBlocked: Bool, safariRequested: Bool) {
            self.accessibility = accessibility
            self.expansionEnabled = expansionEnabled
            self.safariBlocked = safariBlocked
            self.safariRequested = safariRequested
        }
    }

    /// The permissions still missing, required ones first.
    public static func missing(_ s: State) -> [Need] {
        var needs: [Need] = []
        if !s.accessibility {
            needs.append(Need(kind: .accessibility, title: "Accessibility",
                              why: s.expansionEnabled ? "text expansion and pasting into apps" : "pasting into apps (↵ on a clip or snippet)",
                              required: s.expansionEnabled))
        }
        if s.safariBlocked {
            needs.append(Need(kind: .fullDiskAccess, title: "Full Disk Access", why: "Safari history in search",
                              required: s.safariRequested))
        }
        return needs.sorted { $0.required && !$1.required }
    }

    /// One line for the footer, only when something you turned on is waiting.
    public static func footer(_ needs: [Need]) -> String? {
        let required = needs.filter(\.required).map(\.title)
        guard !required.isEmpty else { return nil }
        return "⚠︎ Euclid needs \(required.joined(separator: " and ")) access: type “permissions”"
    }

    /// The row's detail line.
    public static func summary(_ needs: [Need]) -> String {
        guard !needs.isEmpty else { return "Everything Euclid uses is allowed" }
        return needs.map { "\($0.title): \($0.why)\($0.required ? "" : " (optional)")" }.joined(separator: " · ")
    }

    public static func pane(_ kind: Kind) -> URL {
        let anchor = kind == .accessibility ? "Privacy_Accessibility" : "Privacy_AllFiles"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}
