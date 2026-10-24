import Foundation
import EuclidCore

/// Reads exported files for `LauncherImport`, unpacking Alfred's `.alfredsnippets` zips.
enum LauncherImporter {
    /// What the files hold, and a "Raycast" / "Alfred" label for the config comment.
    static func read(_ urls: [URL], existing: Set<String>) -> (LauncherImport.Result, source: String) {
        var result = LauncherImport.Result()
        var sources = Set<String>()
        for url in urls {
            if url.pathExtension.lowercased() == "alfredsnippets" {
                sources.insert("Alfred")
                for file in unzip(url) {
                    guard let data = try? Data(contentsOf: file) else { continue }
                    LauncherImport.parse(data, fileName: file.lastPathComponent, into: &result, existing: existing)
                }
            } else if let data = try? Data(contentsOf: url) {
                sources.insert("Raycast")
                LauncherImport.parse(data, fileName: url.lastPathComponent, into: &result, existing: existing)
            } else {
                result.skipped.append("\(url.lastPathComponent): can't read it")
            }
        }
        let date = Date().formatted(.iso8601.year().month().day())
        return (result, "\(sources.sorted().joined(separator: " and ")) on \(date)")
    }

    /// The JSON files inside an `.alfredsnippets` zip (`ditto` ships with macOS).
    private static func unzip(_ url: URL) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-import-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", url.path, dir.path]
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        return files.sorted { $0.path < $1.path }
    }
}
