import Foundation

/// An installed application.
public struct AppEntry: Sendable, Equatable {
    public let name: String
    public let path: String
    public let bundleID: String?

    public init(name: String, path: String, bundleID: String?) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
    }

    public func searchItem(id: Int) -> SearchItem {
        SearchItem(id: id, title: name, subtitle: path)
    }
}

/// Finds `.app` bundles. A plain directory walk plus one Info.plist read per app:
/// a few hundred apps take ~10 ms, so it runs off the main thread at launch and
/// again when the panel opens if it's older than a minute.
public enum AppIndex {
    public static let defaultFolders = [
        "/Applications",
        "/System/Applications",
        "~/Applications",
        "/System/Library/CoreServices/Finder.app",
    ]

    /// Folders are searched two levels deep (`/Applications/Utilities/…`) without
    /// descending into bundles. The first app found per bundle ID wins.
    public static func scan(folders: [String] = defaultFolders, maxDepth: Int = 2) -> [AppEntry] {
        let fm = FileManager.default
        var apps: [AppEntry] = []
        var seenIDs = Set<String>()
        var seenPaths = Set<String>()

        func add(_ path: String) {
            guard seenPaths.insert(path).inserted, let app = entry(at: path) else { return }
            if let id = app.bundleID, !seenIDs.insert(id).inserted { return }
            apps.append(app)
        }

        func walk(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") { add(path); continue }
                var isDir: ObjCBool = false
                if depth < maxDepth, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    walk(path, depth: depth + 1)
                }
            }
        }

        for folder in folders {
            let path = (folder as NSString).expandingTildeInPath
            if path.hasSuffix(".app") { add(path) } else { walk(path, depth: 1) }
        }
        return apps
    }

    static func entry(at path: String) -> AppEntry? {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: plistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        // Background-only helpers (no Dock icon, no UI) aren't things you launch.
        if info["LSBackgroundOnly"] as? Bool == true { return nil }
        // The file name is what Finder and the Dock show, so it's what you type.
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !name.isEmpty else { return nil }
        return AppEntry(name: name, path: path, bundleID: info["CFBundleIdentifier"] as? String)
    }
}
