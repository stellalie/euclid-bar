import Foundation
import Testing
@testable import EuclidCore

/// The `ai` example: its keys ask a CLI you're logged into and paste the answer back.
struct AIPluginTests {
    private func install() throws -> (Plugin, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-ai-\(UUID().uuidString)")
        let folder = try PluginGuide.installExample("ai", in: dir)
        var issues: [ConfigIssue] = []
        let text = try String(contentsOf: folder.appendingPathComponent("plugin.toml"), encoding: .utf8)
        let plugin = try #require(PluginLoader.parse(text, id: "ai", directory: folder.path, &issues))
        #expect(issues.isEmpty, "\(issues)")
        return (plugin, dir)
    }

    /// A fake `claude` that echoes its prompt back, so the test sees exactly what it was asked.
    private func fakeCLI(in dir: URL) throws -> URL {
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\n[ \"$1\" = -p ] || exit 2\nprintf 'ANSWER\\n%s\\n' \"$2\"\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return bin
    }

    @Test func keysAndAction() throws {
        let (plugin, dir) = try install()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(plugin.keys.map(\.key.symbols) == ["⇧⌘F", "⇧⌘T", "⇧⌘E"])
        #expect(plugin.keys.allSatisfy { $0.when == ["clip", "snippet"] })
        #expect(plugin.answer?.onEnter == true)
        #expect(plugin.answer?.input(for: "ai what is a monad") == "what is a monad")
        #expect(plugin.actions.isEmpty)
        #expect(plugin.settings["language"] == "English")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript")))
    func fixWritingPastesTheAnswer() async throws {
        let (plugin, dir) = try install()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = try fakeCLI(in: dir)
        let clip = #"teh "quoted" \ text $(whoami)"#
        let fix = try #require(plugin.keys.first { $0.name == "Fix writing" })
        let out = try await PluginRunner.output(of: fix.run, plugin: plugin, query: clip, shell: "/bin/zsh", pathPrefix: bin.path,
                                                environment: environment, timeout: .seconds(20))
        let paste = try #require(PluginEffect.parse(out).first?.paste)
        #expect(paste.hasPrefix("ANSWER\nFix the spelling and grammar"))
        #expect(paste.hasSuffix("\n\n" + clip)) // passed through as text, never run
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript")))
    func askAnswersInTheBar() async throws {
        let (plugin, dir) = try install()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = try fakeCLI(in: dir)
        let answer = try #require(plugin.answer)
        let out = try await PluginRunner.output(of: answer.run, plugin: plugin, query: "what is a monad", shell: "/bin/zsh",
                                                pathPrefix: bin.path, environment: environment, timeout: .seconds(20))
        let item = try #require(PluginOutput.parse(out).items.first)
        #expect(item.title == "ANSWER")
        #expect(item.subtitle?.hasPrefix("claude · ") == true)
        #expect(item.preview?.hasSuffix("\n\nwhat is a monad") == true)
        #expect(item.copy == item.preview)
    }

    /// No `$EUCLID_BAR`, so the fake `claude` is picked rather than Apple's model.
    private var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { $0.key != "EUCLID_BAR" && $0.key != "EUCLID_SETTING_CLI" }
    }
}
