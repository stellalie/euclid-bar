import Foundation
import TOMLDecoder

/// Small, layout-keeping edits to `config.toml`, for settings the app changes itself
/// (the menu's "Install Updates Automatically", dragging a source chip). The file stays the one source of truth.
public enum ConfigEditor {
    /// `text` with `[table] key = value` set. Replaces the key's line (keeping its comment),
    /// or adds the key under the table's header, or appends the table.
    /// Nil if the edit wouldn't read back as that value (e.g. the table is written some other way).
    public static func set(_ key: String, to value: Bool, in table: String, text: String) -> String? {
        set(key, literal: value ? "true" : "false", in: table, text: text) { (try? $0.bool(forKey: key)) == value }
    }

    /// `[table] key = ["a", "b"]`, on one line. A list written over several lines is replaced whole.
    public static func set(_ key: String, to value: [String], in table: String, text: String) -> String? {
        let literal = "[" + value.map(quoted).joined(separator: ", ") + "]"
        return set(key, literal: literal, in: table, text: text) { t in
            guard let a = try? t.array(forKey: key), a.count == value.count else { return false }
            return (0..<a.count).allSatisfy { (try? a.string(atIndex: $0)) == value[$0] }
        }
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func set(_ key: String, literal: String, in table: String, text: String,
                            readsBack: (TOMLTable) -> Bool) -> String? {
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
            if line[valueStart...].hasPrefix("["), let (endLine, end) = closingBracket(lines, from: keyLine, at: valueStart) {
                // A list: swap everything up to its `]`, which may be lines further down.
                lines[keyLine] = String(line[..<valueStart]) + literal + lines[endLine][end...]
                lines.removeSubrange((keyLine + 1)..<(endLine + 1))
                return checked(lines, table: table, readsBack)
            }
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
        return checked(lines, table: table, readsBack)
    }

    /// Never write something that reads back differently than intended.
    private static func checked(_ lines: [String], table: String, _ readsBack: (TOMLTable) -> Bool) -> String? {
        let result = lines.joined(separator: "\n")
        guard let parsed = try? TOMLTable(source: result), let t = try? parsed.table(forKey: table), readsBack(t) else { return nil }
        return result
    }

    /// Where the list opening at `start` on line `from` closes: (line, index just past its `]`).
    /// Skips brackets inside strings and comments.
    private static func closingBracket(_ lines: [String], from: Int, at start: String.Index) -> (Int, String.Index)? {
        var depth = 0
        for i in from..<lines.count {
            let line = lines[i]
            var j = i == from ? start : line.startIndex
            var quote: Character?
            while j < line.endIndex {
                let c = line[j]
                if let q = quote {
                    if c == "\\", q == "\"" { j = line.index(after: j) } else if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == "#" {
                    break
                } else if c == "[" {
                    depth += 1
                } else if c == "]" {
                    depth -= 1
                    if depth == 0 { return (i, line.index(after: j)) }
                }
                if j < line.endIndex { j = line.index(after: j) }
            }
        }
        return nil
    }
}
