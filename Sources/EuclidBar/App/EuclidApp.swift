import AppKit
import EuclidCore

@main
@MainActor
enum EuclidApp {
    // NSApplication.delegate is weak; keep a strong reference.
    private static let delegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--check-config") { exit(checkConfig()) }
        if CommandLine.arguments.contains("--mcp") { exit(AgentServer.run()) }
        if let i = CommandLine.arguments.firstIndex(of: "--try-plugin") {
            exit(PluginCommands.tryPlugin(Array(CommandLine.arguments.dropFirst(i + 1))))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--plugin") {
            exit(PluginCommands.run(Array(CommandLine.arguments.dropFirst(i + 1))))
        }
        if CommandLine.arguments.contains("--licence-keygen") { exit(LicenceTool.keygen()) }
        if let i = CommandLine.arguments.firstIndex(of: "--issue-licence") {
            exit(LicenceTool.issue(Array(CommandLine.arguments.dropFirst(i + 1))))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--import") {
            // Print TOML for Raycast/Alfred exports, e.g. `--import snippets.json >> config.toml`.
            let urls = CommandLine.arguments.dropFirst(i + 1).map { URL(fileURLWithPath: $0) }
            let (result, source) = LauncherImporter.read(urls, existing: [])
            for line in result.skipped { FileHandle.standardError.write(Data("skipped: \(line)\n".utf8)) }
            print(LauncherImport.toml(result, source: source), terminator: "")
            exit(result.isEmpty ? 1 : 0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-icon") {
            _ = NSApplication.shared
            let out = CommandLine.arguments.dropFirst(i + 1).first ?? "Resources/AppIcon.icns"
            do { try IconRenderer.render(to: URL(fileURLWithPath: out)) } catch { print("error: \(error)"); exit(1) }
            exit(0)
        }
        if CommandLine.arguments.contains("--speed-budget") { exit(speedBudget()) }
        if let i = CommandLine.arguments.firstIndex(of: "--render-screens") {
            _ = NSApplication.shared
            let dir = CommandLine.arguments.dropFirst(i + 1).first ?? "screens"
            do { try ScreensRenderer.render(to: URL(fileURLWithPath: dir)) } catch { print("error: \(error)"); exit(1) }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-demo") {
            _ = NSApplication.shared
            let dir = CommandLine.arguments.dropFirst(i + 1).first ?? "docs"
            do { try DemoRenderer.render(to: URL(fileURLWithPath: dir)) } catch { print("error: \(error)"); exit(1) }
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no Dock icon, no menu bar takeover
        app.delegate = delegate
        app.run()
    }

    /// `euclid-bar --speed-budget`: time every keystroke over 10k+ items. Exit 1 = over budget.
    private static func speedBudget() -> Int32 {
        let r = SearchBudget.run()
        let worst = r.worst
        print("\(r.items.formatted()) items, \(r.timings.count) keystrokes, slowest \"\(worst.query)\" \(worst.time) (budget \(SearchBudget.limit))")
        if !r.passed { print("error: search is over its speed budget") }
        return r.passed ? 0 : 1
    }

    /// `euclid-bar --check-config`: validate config.toml and print problems. Exit 0 = clean.
    private static func checkConfig() -> Int32 {
        let paths = EuclidPaths()
        print("config: \(paths.configFile.path)")
        print("data:   \(paths.dataDirectory.path)")
        do {
            let loaded = try ConfigLoader.loadOrCreate(at: paths.configFile)
            let c = loaded.config
            for file in loaded.includedFiles { print("include: \(file)") }
            print("theme: \(c.appearance.theme)")
            print("hotkey: \(c.hotkey.map { ($0.modifiers.map(\.rawValue).sorted() + [$0.key]).joined(separator: "+") } ?? "(app setting)")")
            for (i, a) in c.actions.enumerated() {
                print("  \(i < 9 ? "⌘\(i + 1)" : "  ") \(a.name)  [\(a.output.rawValue)]")
            }
            for p in c.plugins {
                let parts = [p.source.map { _ in "source" }, p.answer.map { _ in "answer" }, p.badge.map { _ in "badge" },
                             p.actions.isEmpty ? nil : "\(p.actions.count) action(s)"].compactMap { $0 }
                print("plugin: \(p.id)  \(p.name)  [\(parts.joined(separator: ", "))]  \(p.directory)")
            }
            for issue in loaded.issues { print(issue) }
            print(loaded.issues.isEmpty ? "OK" : "\(loaded.issues.count) issue(s)")
            return loaded.issues.isEmpty ? 0 : 1
        } catch {
            print("error: \(error)")
            return 2
        }
    }
}
