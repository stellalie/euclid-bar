import Foundation
import TOMLDecoder

/// Small, layout-keeping edits to `config.toml`, for settings the app changes itself
/// (the menu's "Install Updates Automatically"). The file stays the one source of truth.
public enum ConfigEditor {
    /// `text` with `[table] key = value` set. Replaces the key's line (keeping its comment),
    /// or adds the key under the table's header, or appends the table.
    /// Nil if the edit wouldn't read back as that value (e.g. the table is written some other way).
    public static func set(_ key: String, to value: Bool, in table: String, text: String) -> String? {
        let literal = value ? "true" : "false"
        var lines = text.components(separatedBy: "\n")
        var header: Int?          // line of `[table]`
        var keyLine: Int?
        var inMultiline = false   // inside a """ or ''' string: nothing there is a header or key
        for (i, line) in lines.enumerated() {
            let wasInMultiline = inMultiline
            if line.components(separatedBy: "\"\"\"").count % 2 == 0 || line.components(separatedBy: "'''").count % 2 == 0 {
                inMultiline.toggle()
            }
            if wasInMultiline { continue }
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("[") {
                if header != nil { break } // the next table: ours ended
                let name = code.dropFirst().prefix { $0 != "]" }.trimmingCharacters(in: .whitespaces)
                if !code.hasPrefix("[["), name == table { header = i }
            } else if header != nil, code.range(of: "^\(key)\\s*=", options: .regularExpression) != nil {
                keyLine = i
                break
            }
        }

        if let keyLine {
            // Swap just the value, keeping indentation, alignment and any trailing comment.
            let line = lines[keyLine]
            let eq = line.firstIndex(of: "=")!
            let afterEq = line[line.index(after: eq)...]
            let valueStart = afterEq.firstIndex { $0 != " " && $0 != "\t" } ?? afterEq.endIndex
            let valueEnd = line[valueStart...].firstIndex { $0 == " " || $0 == "\t" || $0 == "#" } ?? line.endIndex
            var tail = String(line[valueEnd...])
            let gap = tail.prefix { $0 == " " }.count
            if gap > 0, tail.dropFirst(gap).hasPrefix("#") { // keep the comment's column
                let width = line.distance(from: valueStart, to: valueEnd) + gap - literal.count
                tail = String(repeating: " ", count: max(1, width)) + tail.dropFirst(gap)
            }
            lines[keyLine] = String(line[..<valueStart]) + literal + tail
        } else if let header {
            lines.insert("\(key) = \(literal)", at: header + 1)
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            if lines.count > 1 { lines.insert("", at: lines.count - 1) }
            lines.insert(contentsOf: ["[\(table)]", "\(key) = \(literal)"], at: lines.count - 1)
        }
        let result = lines.joined(separator: "\n")

        // Never write something that reads back differently than intended.
        guard let parsed = try? TOMLTable(source: result), let t = try? parsed.table(forKey: table),
              (try? t.bool(forKey: key)) == value else { return nil }
        return result
    }
}
