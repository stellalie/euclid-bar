import AppKit
import EuclidCore

@main
@MainActor
enum EuclidApp {
    // NSApplication.delegate is weak; keep a strong reference.
    private static let delegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--check-config") { exit(checkConfig()) }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no Dock icon, no menu bar takeover
        app.delegate = delegate
        app.run()
    }

    /// `euclid-bar --check-config`: validate config.toml and print problems. Exit 0 = clean.
    private static func checkConfig() -> Int32 {
        let paths = EuclidPaths()
        print("config: \(paths.configFile.path)")
        print("data:   \(paths.dataDirectory.path)")
        do {
            let loaded = try ConfigLoader.loadOrCreate(at: paths.configFile)
            let c = loaded.config
            print("hotkey: \(c.hotkey.map { ($0.modifiers.map(\.rawValue).sorted() + [$0.key]).joined(separator: "+") } ?? "(app setting)")")
            for (i, a) in c.actions.enumerated() {
                print("  \(i < 9 ? "⌘\(i + 1)" : "  ") \(a.name)  [\(a.output.rawValue)]")
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
