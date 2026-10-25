import Foundation

/// `euclid-bar --plugin list`: every installed plugin, on or off, as a table.
public enum PluginList {
    public struct Row: Equatable {
        public let id: String, name: String, on: Bool
    }

    public static func rows(_ config: EuclidConfig) -> [Row] {
        var rows = config.plugins.map { Row(id: $0.id, name: $0.name, on: true) }
        var seen = Set(rows.map(\.id))
        let fm = FileManager.default
        for dir in config.pluginDirectories {
            for id in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where config.pluginsDisabled.contains(id) {
                let folder = (dir as NSString).appendingPathComponent(id)
                guard let text = try? String(contentsOfFile: (folder as NSString).appendingPathComponent(PluginLoader.manifestName), encoding: .utf8),
                      seen.insert(id).inserted else { continue }
                var ignored: [ConfigIssue] = []
                rows.append(Row(id: id, name: PluginLoader.parse(text, id: id, directory: folder, &ignored)?.name ?? id, on: false))
            }
        }
        return rows.sorted { $0.id < $1.id }
    }

    public static func lines(_ config: EuclidConfig) -> [String] {
        let rows = rows(config)
        guard !rows.isEmpty else { return ["No plugins yet."] }
        let width = max(6, rows.map(\.id.count).max() ?? 0)
        func pad(_ s: String) -> String { s.padding(toLength: width, withPad: " ", startingAt: 0) }
        return ["\(pad("PLUGIN"))  ON   NAME"] + rows.map { "\(pad($0.id))  \($0.on ? "on " : "off")  \($0.name)" }
    }
}
