/// A user-defined action: a shell command run with the query as `$1`.
public struct Action: Equatable, Sendable {
    /// Where the command's output goes. Terminals (Ghostty, herdr…) are not
    /// outputs: they're just commands, e.g. `ghostty-run tab pi "$1"`.
    public enum Output: String, Sendable, CaseIterable {
        case background
        case panel

        /// Outputs implemented so far. Others parse, but the action is disabled with a warning.
        public var isAvailable: Bool { self == .background }
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
