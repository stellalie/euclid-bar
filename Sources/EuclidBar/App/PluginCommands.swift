import Foundation
import EuclidCore

/// `euclid-bar --try-plugin <id> [query]` and `euclid-bar --plugin add|list`.
enum PluginCommands {
    /// Run a plugin once and print what the bar would show. Exit 0 = it works.
    static func tryPlugin(_ args: [String]) -> Int32 {
        guard let target = args.first else {
            print("usage: euclid-bar --try-plugin <id or folder> [query]")
            return 64
        }
        let paths = EuclidPaths()
        let query = args.dropFirst().joined(separator: " ")
        let loaded = try? ConfigLoader.loadOrCreate(at: paths.configFile)
        let config = loaded?.config ?? EuclidConfig()
        for issue in loaded?.issues ?? [] where issue.message.hasPrefix("plugin \(target):") { print(issue) }

        var plugin = config.plugins.first { $0.id == target }
        if plugin == nil { // a folder, e.g. one that isn't installed yet
            let folder = URL(fileURLWithPath: (target as NSString).expandingTildeInPath).standardizedFileURL
            let manifest = folder.appendingPathComponent(PluginLoader.manifestName)
            if let text = try? String(contentsOf: manifest, encoding: .utf8) {
                var issues: [ConfigIssue] = []
                plugin = PluginLoader.parse(text, id: folder.lastPathComponent, directory: folder.path, &issues)
                for issue in issues { print("plugin \(folder.lastPathComponent): \(issue)") }
            }
        }
        guard let plugin else {
            let installed = config.plugins.map(\.id)
            print("no plugin '\(target)' in \(paths.pluginsDirectory.path)" + (installed.isEmpty ? "" : " (installed: \(installed.joined(separator: ", ")))"))
            return 1
        }

        let env = ProcessInfo.processInfo.environment.merging(config.environment) { $1 }
        let box = ReportBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.result = await PluginTrial.run(plugin, query: query, shell: config.shellPath,
                                               pathPrefix: paths.binDirectory.path, environment: env)
            done.signal()
        }
        done.wait()
        print(box.result.report)
        return box.result.ok ? 0 : 1
    }

    static func run(_ args: [String]) -> Int32 {
        let paths = EuclidPaths()
        try? PluginGuide.install(in: paths.pluginsDirectory)
        switch (args.first, args.dropFirst().first) {
        case ("add", let what?):
            return add(what, into: paths.pluginsDirectory)
        case ("list", nil):
            let loaded = try? ConfigLoader.loadOrCreate(at: paths.configFile)
            for p in loaded?.config.plugins ?? [] { print("\(p.id)  \(p.name)  \(p.description)") }
            print("examples you can add: \(PluginGuide.examples.keys.sorted().joined(separator: ", "))")
            print("guide: \(paths.pluginsDirectory.appendingPathComponent("AGENTS.md").path)")
            return 0
        default:
            print("""
                usage: euclid-bar --plugin add <example | git URL>   install a plugin
                       euclid-bar --plugin list                      what's installed
                       euclid-bar --try-plugin <id> [query]          run one and show its rows
                examples: \(PluginGuide.examples.keys.sorted().joined(separator: ", "))
                """)
            return 64
        }
    }

    /// An example by name, or a git repository (cloned, then shown so you can read what it runs).
    private static func add(_ what: String, into dir: URL) -> Int32 {
        if PluginGuide.examples[what] != nil {
            do {
                let folder = try PluginGuide.installExample(what, in: dir)
                print("added \(what) to \(folder.path)")
                print("try it: euclid-bar --try-plugin \(what)")
                return 0
            } catch {
                print("error: \(error)")
                return 1
            }
        }
        guard what.contains("://") || what.hasPrefix("git@") else {
            print("error: '\(what)' is neither an example (\(PluginGuide.examples.keys.sorted().joined(separator: ", "))) nor a git URL")
            return 64
        }
        var name = URL(string: what)?.lastPathComponent ?? (what as NSString).lastPathComponent
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        name = name.replacingOccurrences(of: "euclid-plugin-", with: "").lowercased()
        let folder = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            print("error: \(folder.path) already exists")
            return 1
        }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["clone", "--depth", "1", "--", what, folder.path]
        do { try git.run() } catch {
            print("error: can't run git: \(error.localizedDescription)")
            return 1
        }
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { return git.terminationStatus }
        let manifest = folder.appendingPathComponent(PluginLoader.manifestName)
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: folder)
            print("error: that repository has no plugin.toml at its top level; removed it again")
            return 1
        }
        print("added \(name) to \(folder.path). It runs these commands; read them:\n")
        print(text)
        print("try it: euclid-bar --try-plugin \(name)   ·   turn it off: [plugins] disabled = [\"\(name)\"]")
        return 0
    }
}

private final class ReportBox: @unchecked Sendable {
    var result: (report: String, ok: Bool) = ("", false)
}
