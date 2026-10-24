import AppKit
import EuclidCore

/// One row in the results list.
enum Row {
    /// A sticky section title ("Applications", "Clipboard"…). Never selectable.
    case header(String)
    case clip(SearchItem)
    case history(SearchItem)
    /// `number` is the 1-based position in the action list (⌘1 = 1).
    case action(number: Int, Action)
    /// An action reached by its alias: "gh swift testing" runs it on "swift testing".
    case aliasAction(Action, argument: String)
    case builtin(Builtin, clipID: Int)
    /// `subtitle` is the app's path.
    case app(SearchItem)
    case project(ProjectEntry)
    case file(FileHit)
    case calc(Calculator.Result, expression: String)
    case transform(DevTransforms.Result)
    /// `item.id` indexes the configured snippets.
    case snippet(SearchItem, Snippet)
    case content(ContentHit)
    case bitbucket(BitbucketItem)

    var isHeader: Bool { if case .header = self { true } else { false } }

    /// Stable identity for learned ranking. Nil for things that aren't worth learning
    /// (clips already reorder themselves on use; a calculation is never the same twice).
    var learnKey: String? {
        switch self {
        case .app(let item): "app:\(item.subtitle)"
        case .project(let p): "proj:\(p.path)"
        case .file(let f): "file:\(f.path)"
        case .action(_, let a), .aliasAction(let a, _): "action:\(a.name)"
        case .snippet(_, let s): "snippet:\(s.name)"
        case .bitbucket(let b): "bb:\(b.url)"
        case .content(let c): "content:\(c.ref)"
        case .header, .clip, .history, .builtin, .calc, .transform: nil
        }
    }

    /// The path a row stands for, for ⌘C and icons.
    var path: String? {
        switch self {
        case .app(let item): item.subtitle
        case .project(let p): p.path
        case .file(let f): f.path
        case .content(let c) where c.kind == .note: c.ref
        default: nil
        }
    }

    /// Identity across refreshes, to keep the selection where it was.
    var key: String {
        switch self {
        case .header(let t): "#\(t)"
        case .clip(let item): "c\(item.id)"
        case .history(let item): "h\(item.title)\(item.subtitle)"
        case .action(let n, _): "a\(n)"
        case .aliasAction(let a, let arg): "a\(a.name)\u{0}\(arg)"
        case .builtin(let b, _): "b\(b.rawValue)"
        case .app(let item): "p\(item.subtitle)"
        case .project(let p): "p\(p.path)"
        case .file(let f): "p\(f.path)"
        case .calc(let r, _): "=\(r.text)"
        case .transform(let t): "t\(t.label)\u{0}\(t.value)"
        case .snippet(_, let s): "s\(s.name)"
        case .content(let c): "p\(c.ref)"
        case .bitbucket(let b): "u\(b.url)"
        }
    }

    /// Which section the row is listed under while searching.
    var section: String {
        switch self {
        case .header(let t): t
        case .clip: "Clipboard"
        case .history: "Browser History"
        case .action, .aliasAction, .builtin: "Actions"
        case .app: "Applications"
        case .project: "Projects"
        case .file: "Files"
        case .calc, .transform: "Answers"
        case .snippet: "Snippets"
        case .content(let c): c.kind == .note ? "Notes" : "Pages"
        case .bitbucket: "Bitbucket"
        }
    }

    enum Builtin: String, CaseIterable {
        case paste = "Paste clip", copy = "Copy clip", delete = "Delete clip"
        var icon: String { ["Paste clip": "text.insert", "Copy clip": "doc.on.doc", "Delete clip": "trash"][rawValue]! }
        var hint: String { ["Paste clip": "↵", "Copy clip": "⌘C", "Delete clip": "⌘⌫"][rawValue]! }
    }
}

extension [Row] {
    /// Group rows under section headers. Sections are ordered by their best
    /// (first) row and rows keep their order inside a section, so the top hit stays first.
    func sectioned() -> [Row] {
        var order: [String] = []
        var groups: [String: [Row]] = [:]
        for row in self {
            let s = row.section
            if groups[s] == nil { order.append(s) }
            groups[s, default: []].append(row)
        }
        return order.flatMap { [Row.header($0)] + groups[$0]! }
    }
}
