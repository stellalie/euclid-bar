import Foundation

/// An AI's reply turned into file changes in the config folder: found, checked as a whole in a
/// scratch copy, then written with a backup that Undo / Restore Previous Settings puts back.
public enum SettingsChange {
    /// One file the reply writes, relative to the config folder.
    public struct File: Equatable, Sendable {
        public let path: String
        public let text: String
        /// Didn't exist before.
        public let isNew: Bool
        /// Lines that aren't blank or comments, only in the old file and only in the new one.
        public let removed: [String]
        public let added: [String]
        /// A script (`#!` first line, or in bin/): made runnable, and it runs on your Mac.
        public var isScript: Bool { text.hasPrefix("#!") || path.hasPrefix("bin/") }
    }

    public struct Review: Equatable, Sendable {
        public let files: [File]
        /// config.toml drops much more than it adds: likely just the changed part, not the whole file.
        public var looksPartial: Bool {
            guard let c = files.first(where: { $0.path == "config.toml" }), !c.isNew else { return false }
            return c.removed.count >= 5 && c.removed.count > c.added.count * 2
        }
    }

    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case empty
        case unchanged
        /// Paths outside what a reply may write.
        case notAllowed([String])
        /// Problems the reply would add (bad TOML, unknown keys, broken plugins). Nothing is written.
        case problems([String])
        public var description: String {
            switch self {
            case .empty: "The clipboard has no text. Copy the AI's whole reply first."
            case .unchanged: "That's the same as your current settings, so nothing changed."
            case .notAllowed(let p): "The reply writes outside Euclid's settings, so nothing was saved: \(p.joined(separator: ", "))"
            case .problems(let p): "The reply has problems, so nothing was saved:\n" + p.prefix(6).map { "• \($0)" }.joined(separator: "\n")
            }
        }
    }

    // MARK: Finding files in a reply

    /// Code blocks in a reply, each with the path named on the line before it ("File: `x`").
    /// With no named block, the longest block (or the whole text, when it has no fence) is config.toml.
    public static func files(in reply: String) -> [(path: String, text: String)] {
        var named: [(String, String)] = []
        var blocks: [String] = []
        var open: [String]?
        var openPath: String?
        var lastLine = ""
        func close() {
            guard let lines = open else { return }
            let text = lines.joined(separator: "\n")
            blocks.append(text)
            if let openPath { named.append((openPath, text)) }
            open = nil
        }
        for line in reply.components(separatedBy: .newlines) {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("```") {
                if open != nil { close(); lastLine = "" } else { open = []; openPath = path(namedIn: lastLine) }
            } else if open != nil {
                open?.append(line)
            } else if !code.isEmpty {
                lastLine = code
            }
        }
        close() // reply cut off mid-block
        let result: [(String, String)] = named.isEmpty
            ? (blocks.max { $0.count < $1.count } ?? reply).nonEmpty.map { [("config.toml", $0)] } ?? []
            : named
        return result.compactMap { path, text in
            let t = text.trimmingCharacters(in: .newlines)
            return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (path, t + "\n")
        }
    }

    /// `File: \`plugins/x/plugin.toml\``, `**File:** x`, `### plugins/x/run.sh`, `config.toml:`.
    static func path(namedIn line: String) -> String? {
        // "Here's your updated `config.toml`:" names it in backticks.
        for (i, part) in line.components(separatedBy: "`").enumerated() where i % 2 == 1 {
            let p = part.hasPrefix("~/.config/euclid/") ? String(part.dropFirst("~/.config/euclid/".count)) : part
            if isAllowed(p) { return p }
        }
        var s = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_> \t"))
        if let r = s.range(of: #"^(file|path)\W*:"#, options: [.regularExpression, .caseInsensitive]) { s = String(s[r.upperBound...]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "*_` \t:"))
        if s.hasPrefix("~/.config/euclid/") { s.removeFirst("~/.config/euclid/".count) }
        guard !s.isEmpty, !s.contains(" "), s.contains(".") || s.hasPrefix("bin/") else { return nil }
        return s
    }

    /// Where a reply may write: config.toml, `plugins/<id>/…`, `bin/<script>`, `themes/<name>.toml`.
    public static func isAllowed(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix("~") }) else { return false }
        let name = #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
        guard parts.allSatisfy({ $0.range(of: name, options: .regularExpression) != nil }) else { return false }
        switch parts.first {
        case "config.toml": return parts.count == 1
        case "plugins": return (3...4).contains(parts.count) && parts.last != "AGENTS.md"
        case "bin": return parts.count == 2
        case Themes.folderName: return parts.count == 2 && path.hasSuffix(".toml")
        default: return false
        }
    }

    // MARK: Checking

    /// Check a reply against the config folder before anything is written: every file is
    /// written to a scratch copy and the whole setup is loaded from there, like a reload.
    public static func review(_ reply: String, directory: URL) -> Result<Review, Rejection> {
        let proposed = files(in: reply)
        guard !proposed.isEmpty else { return .failure(.empty) }
        let outside = proposed.map(\.path).filter { !isAllowed($0) }
        guard outside.isEmpty else { return .failure(.notAllowed(outside)) }

        let fm = FileManager.default
        var changes: [File] = []
        for (path, text) in proposed {
            let old = try? String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
            guard old?.trimmingCharacters(in: .whitespacesAndNewlines) != text.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            let (removed, added) = settingLines(old ?? "").difference(settingLines(text))
            changes.removeAll { $0.path == path } // named twice: the last one wins
            changes.append(File(path: path, text: text, isNew: old == nil, removed: removed, added: added))
        }
        guard !changes.isEmpty else { return .failure(.unchanged) }

        // Scratch copy of the settings (not .git or anything else in the folder).
        let scratch = fm.temporaryDirectory.appendingPathComponent("euclid-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            for name in ["config.toml", EuclidPaths.pluginsFolderName, "bin", Themes.folderName] {
                let from = directory.appendingPathComponent(name)
                if fm.fileExists(atPath: from.path) { try fm.copyItem(at: from, to: scratch.appendingPathComponent(name)) }
            }
            try write(changes, in: scratch)
        } catch {
            return .failure(.problems(["couldn't check the reply: \(error.localizedDescription)"]))
        }

        let before = Set(problems(in: directory))
        let after = problems(in: scratch).map { $0.replacingOccurrences(of: scratch.path, with: directory.path) }
        let new = after.filter { !before.contains($0) }
        guard new.isEmpty else { return .failure(.problems(new)) }
        return .success(Review(files: changes))
    }

    /// What a reload of this folder would complain about, like the footer and `--check-config`.
    public static func problems(in directory: URL) -> [String] {
        let file = directory.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        do { return try ConfigLoader.parse(text, directory: directory).issues.map(\.message) } catch {
            return ["config.toml isn't valid TOML: \(error.description.replacingOccurrences(of: "config.toml: ", with: ""))"]
        }
    }

    // MARK: Writing, Undo and Restore

    /// Write the reply's files, after saving what they replace to a new folder in `backups`.
    /// Returns that folder: `restore` puts it back.
    public static func apply(_ review: Review, directory: URL, backups: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        var backup = backups.appendingPathComponent(format.string(from: now))
        var n = 1
        while fm.fileExists(atPath: backup.path) { n += 1; backup = backups.appendingPathComponent("\(format.string(from: now))-\(n)") }
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for file in review.files where !file.isNew {
            let to = backup.appendingPathComponent(file.path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try String(contentsOf: directory.appendingPathComponent(file.path), encoding: .utf8).write(to: to, atomically: true, encoding: .utf8)
        }
        let created = review.files.filter(\.isNew).map(\.path)
        try (created.joined(separator: "\n") + "\n").write(to: backup.appendingPathComponent(createdList), atomically: true, encoding: .utf8)
        try write(review.files, in: directory)
        return backup
    }

    /// Put a backup back: old files restored, files the change added removed (and their
    /// folders, when empty). The backup is used up.
    public static func restore(_ backup: URL, directory: URL) throws {
        let fm = FileManager.default
        let created = ((try? String(contentsOf: backup.appendingPathComponent(createdList), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter(isAllowed)
        for path in created {
            let url = directory.appendingPathComponent(path)
            try? fm.removeItem(at: url)
            var folder = url.deletingLastPathComponent()
            while folder.path.count > directory.path.count, (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fm.removeItem(at: folder)
                folder = folder.deletingLastPathComponent()
            }
        }
        let old = (fm.enumerator(atPath: backup.path)?.allObjects as? [String] ?? [])
            .filter { $0 != createdList && isAllowed($0) }
        try write(old.compactMap { path in
            (try? String(contentsOf: backup.appendingPathComponent(path), encoding: .utf8)).map {
                File(path: path, text: $0, isNew: false, removed: [], added: [])
            }
        }, in: directory)
        try fm.removeItem(at: backup)
    }

    /// The newest backup, for Restore Previous Settings.
    public static func latestBackup(in backups: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        return names.filter { $0.first?.isNumber == true }.max().map { backups.appendingPathComponent($0) }
    }

    static let createdList = ".created"

    private static func write(_ files: [File], in directory: URL) throws {
        let fm = FileManager.default
        for file in files {
            let url = directory.appendingPathComponent(file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // In place, not atomically: a symlinked config.toml (dotfiles) stays a symlink.
            try file.text.write(to: url, atomically: false, encoding: .utf8)
            if file.isScript { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
    }

    private static func settingLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Array where Element == String {
    /// Lines only in self, and only in `other`, each in its own order (counting repeats).
    func difference(_ other: [String]) -> ([String], [String]) {
        func minus(_ a: [String], _ b: [String]) -> [String] {
            var counts: [String: Int] = [:]
            for line in b { counts[line, default: 0] += 1 }
            return a.filter { line in
                guard let n = counts[line], n > 0 else { return true }
                counts[line] = n - 1
                return false
            }
        }
        return (minus(self, other), minus(other, self))
    }
}
