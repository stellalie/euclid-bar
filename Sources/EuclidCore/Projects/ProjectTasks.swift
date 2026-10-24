import Foundation

/// Something a project knows how to do: a Makefile target, a package.json script, a just recipe,
/// or the usual commands of its build tool. ⌘K on a project lists them.
public struct ProjectTask: Equatable, Sendable {
    /// "test"
    public let name: String
    /// What runs, for display: "npm run test".
    public let command: String
    /// "package.json", "Makefile", "justfile", "Swift"…
    public let source: String
    /// `cd '<project>' && <command>`, every part shell-quoted: names come from files in the repo,
    /// so a script called `$(rm -rf ~)` is only ever a name.
    public let commandLine: String

    init(name: String, tool: [String], in path: String, source: String) {
        self.name = name
        self.command = (tool + [name]).joined(separator: " ")
        self.source = source
        commandLine = "cd \(ProjectTasks.quote(path)) && " + (tool + [name]).map(ProjectTasks.quote).joined(separator: " ")
    }
}

public enum ProjectTasks {
    /// Per source, so one huge Makefile can't bury the rest.
    public static let limit = 30

    public static func scan(_ path: String, read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [ProjectTask] {
        func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }
        var tasks: [ProjectTask] = []

        if let json = read(file("package.json")) {
            let runner = exists(file("pnpm-lock.yaml")) ? ["pnpm"]
                : exists(file("yarn.lock")) ? ["yarn"]
                : exists(file("bun.lockb")) || exists(file("bun.lock")) ? ["bun", "run"]
                : ["npm", "run"]
            tasks += packageScripts(json).prefix(limit).map { ProjectTask(name: $0, tool: runner, in: path, source: "package.json") }
        }
        if let name = ["Makefile", "makefile", "GNUmakefile"].first(where: { exists(file($0)) }), let text = read(file(name)) {
            tasks += makeTargets(text).prefix(limit).map { ProjectTask(name: $0, tool: ["make"], in: path, source: "Makefile") }
        }
        if let name = ["justfile", "Justfile", ".justfile"].first(where: { exists(file($0)) }), let text = read(file(name)) {
            tasks += justRecipes(text).prefix(limit).map { ProjectTask(name: $0, tool: ["just"], in: path, source: "justfile") }
        }
        for (marker, tool, source, names) in [
            ("Package.swift", ["swift"], "Swift", ["build", "test"]),
            ("Cargo.toml", ["cargo"], "Cargo", ["build", "test", "run"]),
            ("go.mod", ["go"], "Go", ["build", "test"]),
        ] where exists(file(marker)) {
            tasks += names.map { ProjectTask(name: $0, tool: tool, in: path, source: source) }
        }
        return tasks
    }

    /// `"scripts"` keys of a package.json, in file order.
    static func packageScripts(_ json: String) -> [String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let scripts = obj["scripts"] as? [String: Any] else { return [] }
        // JSONSerialization loses key order; recover it from the text.
        return scripts.keys.sorted { (json.range(of: "\"\($0)\"")?.lowerBound ?? json.endIndex) < (json.range(of: "\"\($1)\"")?.lowerBound ?? json.endIndex) }
    }

    /// Explicit targets: `name:` at the start of a line. Not variables (`X := 1`), patterns (`%.o:`),
    /// special targets (`.PHONY:`) or files (`out.o:`, `build/x:`).
    static func makeTargets(_ text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first, first.isLetter || first.isNumber,
                  let colon = line.firstIndex(of: ":"), line[line.index(after: colon)...].first != "=",
                  !line[..<colon].contains("=") else { continue }
            for name in line[..<colon].split(separator: " ").map(String.init)
            where name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil {
                if seen.insert(name).inserted { out.append(name) }
            }
        }
        return out
    }

    /// `recipe:` or `recipe arg:` at the start of a line; settings, aliases and private (`_x`) recipes skipped.
    static func justRecipes(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var s = Substring(line)
            if s.hasPrefix("@") { s = s.dropFirst() }
            guard let first = s.first, first.isLetter,
                  let colon = s.firstIndex(of: ":"), s[s.index(after: colon)...].first != "=" else { continue }
            let head = s[..<colon].split(separator: " ")
            guard let name = head.first.map(String.init), !["set", "alias", "export", "import", "mod"].contains(name),
                  name.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil,
                  !out.contains(name) else { continue }
            out.append(name)
        }
        return out
    }

    /// Single-quoted for the shell.
    static func quote(_ s: String) -> String {
        if s.range(of: #"^[A-Za-z0-9_./:=@%+-]+$"#, options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
