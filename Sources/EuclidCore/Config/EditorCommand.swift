import Foundation

/// The shell command behind Edit Config…, from `editor`. The file arrives as `$1`, like an action's query.
public enum EditorCommand {
    /// - nil: the macOS default text editor (`open -t`).
    /// - contains `$1`: run as written (`"code -n \"$1\""`).
    /// - an app (`"Sublime Text"`, `"/Applications/Zed.app"`): `open -a`.
    /// - anything else is a command given the file: `"subl"`, `"code -n"`.
    public static func command(for editor: String?, isApp: (String) -> Bool) -> String {
        guard let editor, !editor.isEmpty else { return #"open -t "$1""# }
        if editor.contains("$1") { return editor }
        if isApp(editor) { return "open -a \(quoted(editor)) \"$1\"" }
        return "\(editor) \"$1\""
    }

    /// True if `name` is a `.app` path, or `<name>.app` is directly in one of `folders`
    /// (or one level down, like `/Applications/Utilities`).
    public static func isApp(_ name: String, folders: [String] = AppIndex.defaultFolders,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                             subfolders: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }) -> Bool {
        if name.hasSuffix(".app") { return true }
        guard !name.contains("/") else { return false }
        let bundle = name + ".app"
        for folder in folders.map({ ($0 as NSString).expandingTildeInPath }) where !folder.hasSuffix(".app") {
            if exists(folder + "/" + bundle) { return true }
            for sub in subfolders(folder) where !sub.hasSuffix(".app") && exists(folder + "/" + sub + "/" + bundle) { return true }
        }
        return false
    }

    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
