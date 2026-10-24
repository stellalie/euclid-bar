import Foundation
import Testing
@testable import EuclidCore

@Suite struct ProjectTasksTests {
    func scan(_ files: [String: String], at path: String = "/code/app") -> [ProjectTask] {
        ProjectTasks.scan(path, read: { files[($0 as NSString).lastPathComponent] },
                          exists: { files[($0 as NSString).lastPathComponent] != nil })
    }

    @Test func packageScriptsInFileOrderWithTheRightRunner() {
        let json = #"{"name":"x","scripts":{"dev":"vite","test":"vitest","build":"vite build"}}"#
        #expect(scan(["package.json": json]).map(\.command) == ["npm run dev", "npm run test", "npm run build"])
        #expect(scan(["package.json": json, "pnpm-lock.yaml": ""]).first?.command == "pnpm dev")
        #expect(scan(["package.json": json, "yarn.lock": ""]).first?.command == "yarn dev")
        #expect(scan(["package.json": json, "bun.lock": ""]).first?.command == "bun run dev")
        #expect(scan(["package.json": "{}"]).isEmpty)
    }

    @Test func makeTargets() {
        let makefile = """
            .PHONY: all test
            CC := clang
            X ?= a:b
            VERSION = 1
            all build: deps
            \techo hi: there
            test:
            %.o: %.c
            out.o: out.c
            build/x: y
            install:: all
            all: again
            """
        #expect(scan(["Makefile": makefile]).map(\.name) == ["all", "build", "test", "install"])
        #expect(scan(["Makefile": "run:\n"]).first?.source == "Makefile")
    }

    @Test func justRecipes() {
        let justfile = """
            set shell := ["zsh", "-c"]
            alias t := test
            export FOO := "1"
            default: test
            @test *args:
              swift test {{args}}
            deploy env="prod": build
            _private:
            """
        #expect(scan(["justfile": justfile]).map(\.command) == ["just default", "just test", "just deploy"])
    }

    @Test func buildToolDefaults() {
        #expect(scan(["Package.swift": ""]).map(\.command) == ["swift build", "swift test"])
        #expect(scan(["Cargo.toml": ""]).map(\.command) == ["cargo build", "cargo test", "cargo run"])
        #expect(scan(["go.mod": ""]).map(\.command) == ["go build", "go test"])
    }

    @Test func commandLinesKeepRepoTextInert() async throws {
        let json = #"{"scripts":{"$(touch PWNED)":"x","it's":"y"}}"#
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid tasks \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tasks = scan(["package.json": json], at: dir.path)
        #expect(tasks.map(\.commandLine) == [
            "cd '\(dir.path)' && npm run '$(touch PWNED)'",
            "cd '\(dir.path)' && npm run 'it'\\''s'",
        ])
        // The shell sees one literal argument: swap npm for printf and check nothing ran.
        let line = tasks[0].commandLine.replacingOccurrences(of: "npm run", with: "printf %s") + " > out.txt"
        let result = await withCheckedContinuation { c in
            CommandRunner.runInBackground(shell: "/bin/zsh", command: line, query: "") { c.resume(returning: $0) }
        }
        guard case .success = result else { Issue.record("\(result)"); return }
        #expect(try String(contentsOf: dir.appendingPathComponent("out.txt"), encoding: .utf8) == "$(touch PWNED)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("PWNED").path))
    }
}
