import Foundation
import EuclidCore

/// `euclid-bar --theme [name]`: see `ThemeCommand`. Reads and writes config.toml; the running app
/// notices the save and applies the theme.
enum ThemeCLI {
    static func run(_ args: [String]) -> Int32 {
        let paths = EuclidPaths()
        guard let text = try? String(contentsOf: paths.configFile, encoding: .utf8) else {
            FileHandle.standardError.write(Data("error: no \(paths.configFile.path) yet: open Euclid once first\n".utf8))
            return 1
        }
        let current = (try? ConfigLoader.loadOrCreate(at: paths.configFile))?.config.appearance.theme ?? Themes.defaultName
        let folder = paths.configDirectory.appendingPathComponent(Themes.folderName)
        let yours = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".toml") }.map { String($0.dropLast(5)) }
        let r = ThemeCommand.run(args, configText: text, current: current, yourThemes: yours)
        if let newText = r.newText {
            do { try newText.write(to: paths.configFile, atomically: true, encoding: .utf8) } catch {
                FileHandle.standardError.write(Data("error: couldn't write \(paths.configFile.path): \(error.localizedDescription)\n".utf8))
                return 1
            }
        }
        if r.status == 0 { print(r.output) } else { FileHandle.standardError.write(Data((r.output + "\n").utf8)) }
        return r.status
    }
}
