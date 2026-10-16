import Foundation

/// A git repository found under one of the project roots.
public struct ProjectEntry: Sendable, Equatable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    public func searchItem(id: Int) -> SearchItem {
        SearchItem(id: id, title: name, subtitle: ProjectScanner.abbreviate(path),
                   searchText: "\(name) \(ProjectScanner.abbreviate(path))")
    }
}

/// Finds git repositories: any folder containing `.git` (a directory, or a file
/// for worktrees and submodules). Stops descending at a repo, and never walks
/// into dependency or build folders, so even a big `~/code` takes milliseconds.
public enum ProjectScanner {
    static let skipped: Set<String> = [
        "node_modules", "Library", "Pods", "DerivedData", "build", "dist", "target", "vendor", "venv",
    ]

    public static func scan(roots: [String], maxDepth: Int = 3) -> [ProjectEntry] {
        let fm = FileManager.default
        var found: [ProjectEntry] = []
        var seen = Set<String>()

        func walk(_ dir: String, depth: Int) {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                if seen.insert(dir).inserted {
                    found.append(ProjectEntry(name: (dir as NSString).lastPathComponent, path: dir))
                }
                return
            }
            guard depth < maxDepth, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() where !name.hasPrefix(".") && !skipped.contains(name) && !name.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                walk(path, depth: depth + 1)
            }
        }

        for root in roots {
            walk((root as NSString).expandingTildeInPath, depth: 0)
        }
        return found
    }

    /// `/Users/me/code/x` → `~/code/x`
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
