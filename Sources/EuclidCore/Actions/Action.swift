/// A user-defined action: a shell command run with the query as `$1`.
public struct Action: Equatable, Sendable {
    public enum Output: String, Sendable, CaseIterable {
        case background
        case panel
        case ghosttyTab = "ghostty-tab"
        case ghosttySplit = "ghostty-split"
        case herdrTab = "herdr-tab"
        case herdrPane = "herdr-pane"

        /// Outputs implemented so far. Others parse, but the action is disabled with a warning.
        public var isAvailable: Bool { [.background, .ghosttyTab, .ghosttySplit].contains(self) }

        /// Short label for the UI.
        public var label: String? {
            switch self {
            case .background: nil
            case .panel: "panel"
            case .ghosttyTab: "Ghostty tab"
            case .ghosttySplit: "Ghostty split"
            case .herdrTab: "herdr tab"
            case .herdrPane: "herdr pane"
            }
        }
    }

    public let name: String
    public let run: String
    public let output: Output

    public init(name: String, run: String, output: Output = .background) {
        self.name = name
        self.run = run
        self.output = output
    }
}
