import Foundation
import Testing
@testable import EuclidCore

/// `euclid-bar --completions zsh`, run in a real zsh with compadd/_describe stubbed to print
/// what they'd offer, against a fake euclid-bar.
@Suite struct CompletionsTests {
    static let zsh = ["/bin/zsh", "/usr/bin/zsh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    func complete(_ line: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-comp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Completions.zsh().write(to: dir.appendingPathComponent("_euclid-bar"), atomically: true, encoding: .utf8)
        // A fake euclid-bar that prints what the real one does for --tool and --theme.
        try """
            #!/bin/sh
            case $1 in
              --tool) printf 'usage: euclid-bar --tool <name> [key=value…]\\n\\nsearch_clipboard  Search it.\\neuclid_shortcuts  Keys.\\n' ;;
              --theme) printf '  default\\n* nord\\n  midnight  (themes/midnight.toml)\\n\\neuclid-bar --theme <name> switches; Euclid applies it at once.\\n' ;;
            esac
            """.writeScript(to: dir.appendingPathComponent("euclid-bar"))
        let words = line.map { "'\($0)'" }.joined(separator: " ")
        let driver = """
            compadd() { local a; while (( $# )); do case $1 in -a) shift; print -l -- ${(P)1}; shift ;; --) shift ;; -*) shift ;; *) print -- $1; shift ;; esac; done }
            _describe() { local -a items=(${(P)${@[-1]}}); print -l -- ${items%%:*} }
            words=(\(words)); CURRENT=$#words
            source \(dir.path)/_euclid-bar
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try #require(Self.zsh))
        p.arguments = ["-f", "-c", driver]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @Test(.enabled(if: zsh != nil)) func completesFlagsToolsThemesAndPlugins() throws {
        #expect(try complete(["euclid-bar", ""]).prefix(3) == ["--tool", "--theme", "--plugin"])
        #expect(try complete(["euclid-bar", "--tool", ""]) == ["search_clipboard", "euclid_shortcuts"])
        #expect(try complete(["euclid-bar", "--theme", ""]) == ["--next", "--prev", "default", "nord", "midnight"])
        #expect(try complete(["euclid-bar", "--plugin", ""]) == ["add", "list"])
        let examples = try complete(["euclid-bar", "--plugin", "add", ""])
        #expect(examples.contains("herdr") && examples.contains("claude-sessions") && examples.contains("handoff"))
        #expect(try complete(["euclid-bar", "--tool", "search_clipboard", ""]).isEmpty)
    }

    @Test(.enabled(if: zsh != nil)) func scriptIsValidZsh() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-comp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Completions.zsh().write(to: file, atomically: true, encoding: .utf8)
        let p = try Process.run(URL(fileURLWithPath: try #require(Self.zsh)), arguments: ["-n", file.path])
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(Completions.zsh().hasPrefix("#compdef euclid-bar\n"))
    }

    static let bash = ["/bin/bash", "/usr/bin/bash"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static let fish = ["/usr/bin/fish", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs `script` in `shell` with a fake euclid-bar first on PATH; returns its stdout lines.
    func runShell(_ shell: String, _ script: String, files: [String: String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-comp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try """
            #!/bin/sh
            case $1 in
              --tool) printf 'usage: euclid-bar --tool <name> [key=value…]\\n\\nsearch_clipboard  Search it.\\neuclid_shortcuts  Keys.\\n' ;;
              --theme) printf '  default\\n* nord\\n  midnight  (themes/midnight.toml)\\n\\neuclid-bar --theme <name> switches.\\n' ;;
            esac
            """.writeScript(to: dir.appendingPathComponent("euclid-bar"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", script.replacingOccurrences(of: "$DIR", with: dir.path)]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["XDG_CONFIG_HOME"] = dir.path // fish: no user config
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @Test(.enabled(if: bash != nil)) func bashCompletes() throws {
        func complete(_ words: [String]) throws -> [String] {
            let list = words.map { "'\($0)'" }.joined(separator: " ")
            return try runShell(try #require(Self.bash), """
                source $DIR/euclid-bar.bash
                COMP_WORDS=(\(list)); COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
                _euclid_bar; printf '%s\\n' "${COMPREPLY[@]}"
                """, files: ["euclid-bar.bash": Completions.bash()])
        }
        #expect(try complete(["euclid-bar", "--t"]) == ["--tool", "--theme", "--try-plugin"])
        #expect(try complete(["euclid-bar", "--tool", ""]) == ["search_clipboard", "euclid_shortcuts"])
        #expect(try complete(["euclid-bar", "--theme", "mi"]) == ["midnight"])
        #expect(try complete(["euclid-bar", "--theme", "--n"]) == ["--next"])
        #expect(try complete(["euclid-bar", "--plugin", "add", "her"]) == ["herdr"])
        #expect(try complete(["euclid-bar", "--completions", ""]) == ["zsh", "bash", "fish"])
    }

    @Test(.enabled(if: fish != nil)) func fishCompletes() throws {
        func complete(_ line: String) throws -> [String] {
            try runShell(try #require(Self.fish), "source $DIR/euclid-bar.fish; complete -C '\(line)'",
                         files: ["euclid-bar.fish": Completions.fish()]).map { String($0.prefix { $0 != "\t" }) }
        }
        #expect(try complete("euclid-bar --t").sorted() == ["--theme", "--tool", "--try-plugin"])
        #expect(try complete("euclid-bar --tool ").sorted() == ["euclid_shortcuts", "search_clipboard"])
        #expect(try complete("euclid-bar --theme ").sorted() == ["--next", "--prev", "default", "midnight", "nord"])
        #expect(try complete("euclid-bar --plugin ").sorted() == ["add", "list"])
        #expect(try complete("euclid-bar --plugin add her") == ["herdr"])
        #expect(try complete("euclid-bar --tool search_clipboard ").isEmpty)
    }

    @Test func everyShellHasAScript() {
        #expect(Completions.shells.allSatisfy { Completions.script(for: $0) != nil })
        #expect(Completions.script(for: "tcsh") == nil)
    }
}
