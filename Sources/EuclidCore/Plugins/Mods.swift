import Foundation

/// What a hook or a `[[key]]` script asks Euclid to do, one JSON object per line:
///
///     {"notice":"Cleaned 2 tracking links"}
///     {"copy":"https://example.com/page"}
///
/// Lines that aren't JSON objects are ignored, so a script can also log.
public struct PluginEffect: Equatable, Sendable, Decodable {
    /// Shown in the panel's footer (now, or the next time it opens).
    public var notice: String?
    /// Put this text on the clipboard.
    public var copy: String?
    /// Open this URL or file path.
    public var open: String?
    /// `open` hooks only: start the search with this text, unless you already typed.
    public var query: String?

    public init(notice: String? = nil, copy: String? = nil, open: String? = nil, query: String? = nil) {
        self.notice = notice
        self.copy = copy
        self.open = open
        self.query = query
    }

    public static func parse(_ data: Data) -> [PluginEffect] {
        String(decoding: data.prefix(256 * 1024), as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), let e = try? JSONDecoder().decode(PluginEffect.self, from: Data(t.utf8)),
                  e != PluginEffect() else { return nil }
            return e
        }
    }
}

/// The selected result, as `[[key]]` and `choose` hook scripts see it.
public struct ModItem: Equatable, Sendable {
    /// app, project, file, clip, page, note, history, pr, issue, snippet, action, answer, task, command or plugin.
    public let kind: String
    public let title: String
    public var subtitle = ""
    public var url: String?
    public var path: String?
    public var text: String?
    /// For a plugin's item: the plugin's id.
    public var pluginID: String?

    public init(kind: String, title: String, subtitle: String = "", url: String? = nil, path: String? = nil,
                text: String? = nil, pluginID: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.path = path
        self.text = text
        self.pluginID = pluginID
    }

    /// `$1`: the thing itself — its URL, path or text, else its title.
    public var value: String { url ?? path ?? text ?? title }

    public var environment: [String: String] {
        var env = ["EUCLID_ITEM_KIND": kind, "EUCLID_ITEM_TITLE": title, "EUCLID_ITEM_SUBTITLE": subtitle]
        if let url { env["EUCLID_ITEM_URL"] = url }
        if let path { env["EUCLID_ITEM_PATH"] = path }
        if let text { env["EUCLID_ITEM_TEXT"] = String(text.prefix(100_000)) }
        if let pluginID { env["EUCLID_ITEM_PLUGIN"] = pluginID }
        return env
    }
}

/// `mod: <what you want>` typed in the bar: the request handed to your coding agent.
public enum ModRequest {
    /// What `mod:` text means: nil when it isn't a mod request.
    public enum Parsed: Equatable { case make(String), undo }

    public static func parse(_ query: String) -> Parsed? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.lowercased().hasPrefix("mod:") else { return nil }
        let rest = q.dropFirst(4).trimmingCharacters(in: .whitespaces)
        if rest.lowercased() == "undo" { return .undo }
        return rest.isEmpty ? nil : .make(rest)
    }

    /// The prompt: enough for an agent that has never seen Euclid.
    public static func prompt(_ request: String, executable: String) -> String {
        """
        Make a Euclid mod: \(request)

        Euclid is my macOS launcher. A mod is a plugin folder in this directory. Read AGENTS.md here first: \
        it is the whole format (sources, answers, badges, actions, [[on]] hooks, [[key]] shortcuts). Make a new folder \
        for this mod (or change the plugin it clearly belongs to), then run \
        `\(executable) --try-plugin <folder>` and fix it until it prints OK. Euclid loads it as soon as you save. \
        Keep it small and readable, and tell me how to use it when you're done.
        """
    }

    /// One shell command line: in the plugins folder, start the agent with the prompt.
    /// `agent` is the CLI as you'd type it (`claude`, `codex`), and gets the prompt as its one argument.
    public static func commandLine(agent: String, prompt: String, directory: String) -> String {
        "cd \(quote(directory)) && \(agent) \(quote(prompt))"
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}

/// `mod: undo`: the plugins folder is a git repository; every `mod:` request first commits
/// what's there, so undo puts the folder back as it was before the last request.
public enum ModHistory {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// Commit everything in `directory` (making it a repository the first time).
    public static func snapshot(_ directory: URL, message: String) throws {
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            try git(directory, ["init", "-q"])
        }
        try git(directory, ["add", "-A"])
        try git(directory, ["commit", "-q", "--allow-empty", "-m", message])
    }

    /// Undo the last mod. Changes since the last snapshot are stashed (`git stash pop` brings them
    /// back); with none, the last snapshot itself is dropped. Returns what happened, for the footer.
    @discardableResult
    public static func undo(_ directory: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) else {
            throw Failure(description: "no mods to undo yet")
        }
        if try !git(directory, ["status", "--porcelain"]).isEmpty {
            try git(directory, ["stash", "push", "-u", "-q", "-m", "undone mod"])
            return "Undid the last mod. To bring it back: cd \(directory.path) && git stash pop"
        }
        guard (try? git(directory, ["rev-parse", "-q", "--verify", "HEAD~1"])) != nil else {
            throw Failure(description: "nothing to undo")
        }
        let message = try git(directory, ["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(directory, ["reset", "-q", "--hard", "HEAD~1"])
        return "Undid “\(message.replacingOccurrences(of: "before mod: ", with: ""))”"
    }

    @discardableResult
    static func git(_ directory: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", directory.path, "-c", "user.name=Euclid", "-c", "user.email=euclid@localhost",
                       "-c", "commit.gpgsign=false"] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw Failure(description: "can't run git: \(error.localizedDescription)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let line = String(decoding: errData, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
            throw Failure(description: "git \(args.first ?? ""): \(line ?? "exit \(p.terminationStatus)")")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
