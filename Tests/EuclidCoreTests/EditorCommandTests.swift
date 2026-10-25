import Foundation
import Testing
@testable import EuclidCore

@Suite struct EditorCommandTests {
    @Test func parsesEditor() throws {
        #expect(try ConfigLoader.parse("").config.editor == nil)
        #expect(try ConfigLoader.parse(DefaultConfig.text).config.editor == nil)
        let set = try ConfigLoader.parse(#"editor = " Sublime Text ""#)
        #expect(set.config.editor == "Sublime Text")
        #expect(set.issues.isEmpty)
        #expect(try ConfigLoader.parse(#"editor = """#).config.editor == nil)
        let bad = try ConfigLoader.parse("editor = 1")
        #expect(bad.config.editor == nil)
        #expect(bad.issues.contains { $0.message.hasPrefix("editor must be a string") })
    }

    @Test func commandForEachKind() {
        let apps: Set = ["Sublime Text", "Bob's Editor"]
        func cmd(_ e: String?) -> String { EditorCommand.command(for: e) { apps.contains($0) } }
        #expect(cmd(nil) == #"open -t "$1""#)
        #expect(cmd("Sublime Text") == #"open -a 'Sublime Text' "$1""#)
        #expect(cmd("Bob's Editor") == #"open -a 'Bob'\''s Editor' "$1""#)
        #expect(cmd("subl") == #"subl "$1""#)
        #expect(cmd("code -n") == #"code -n "$1""#)
        #expect(cmd(#"zed --new "$1""#) == #"zed --new "$1""#)
    }

    @Test func findsAppsInFolders() {
        let present: Set = ["/Applications/Sublime Text.app", "/Applications/Utilities/Console.app"]
        func isApp(_ n: String) -> Bool {
            EditorCommand.isApp(n, folders: ["/Applications", "/System/Library/CoreServices/Finder.app"],
                                exists: { present.contains($0) },
                                subfolders: { $0 == "/Applications" ? ["Sublime Text.app", "Utilities"] : [] })
        }
        #expect(isApp("Sublime Text"))
        #expect(isApp("Console"))
        #expect(isApp("/Applications/Zed.app"))
        #expect(!isApp("subl"))
        #expect(!isApp("code -n"))
        #expect(!isApp("/usr/local/bin/subl"))
    }

    /// The command really opens the file, quoting intact, through the same runner as actions.
    @Test func runsWithTheFileAsFirstArgument() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("args").path
        let file = dir.appendingPathComponent("my config.toml").path
        let p = CommandRunner.makeProcess(shell: "/bin/zsh", command: EditorCommand.command(for: "printf '%s|' >'\(out)'") { _ in false }, query: file)
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(try String(contentsOfFile: out, encoding: .utf8) == file + "|")
    }
}
