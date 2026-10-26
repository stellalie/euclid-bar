import Foundation

/// `euclid-bar --try-plugin <id> [query]`: run every part of a plugin once and print what
/// the bar would show, or exactly what's wrong. Made for the edit-try-fix loop of a person
/// or a coding agent writing a plugin.
public enum PluginTrial {
    public static func run(_ plugin: Plugin, query: String, shell: String, pathPrefix: String?,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           answerTimeout: Duration = PluginTiming.answer) async -> (report: String, ok: Bool) {
        var lines = ["plugin: \(plugin.name) (\(plugin.id))", "folder: \(plugin.directory)"]
        var ok = true
        func attempt(_ label: String, _ command: String, query: String, environment extra: [String: String] = [:],
                     timeout: Duration) async -> Data? {
            do {
                return try await PluginRunner.output(of: command, plugin: plugin, query: query, shell: shell, pathPrefix: pathPrefix,
                                                     environment: environment.merging(extra) { $1 }, timeout: timeout)
            } catch {
                lines.append("\(label): FAILED, \(error)")
                ok = false
                return nil
            }
        }
        func show(_ label: String, _ data: Data) {
            let (items, problems) = PluginOutput.parse(data)
            lines.append("\(label): \(items.count) item(s)")
            for item in items.prefix(20) { lines.append("  " + describe(item)) }
            if items.count > 20 { lines.append("  … \(items.count - 20) more") }
            for p in problems { lines.append("  problem: \(p)") }
            if !problems.isEmpty { ok = false }
        }

        if let source = plugin.source, let data = await attempt("source", source.run, query: "", timeout: PluginTiming.source) {
            show("source", data)
        }
        if let answer = plugin.answer {
            if let input = answer.input(for: query) {
                if let data = await attempt("answer", answer.run, query: input, timeout: answerTimeout) { show("answer for “\(input)”", data) }
            } else {
                let trigger = answer.prefix.map { "start with “\($0) ”" } ?? "match /\(answer.match ?? "")/"
                lines.append("answer: not run; the query must \(trigger) (pass one after the plugin name)")
            }
        }
        if let badge = plugin.badge, let data = await attempt("badge", badge.run, query: "", timeout: PluginTiming.source) {
            if let text = Plugin.Badge.text(from: data) {
                lines.append("badge: \(badge.icon.map { "[\($0)] " } ?? "")\(text)\(badge.click.map { "  (click runs: \($0))" } ?? "")")
            } else {
                lines.append("badge: printed nothing, so it's hidden")
            }
        }
        for a in plugin.actions { lines.append("action: \(a.name)  runs: \(a.run)") }
        for hook in plugin.hooks {
            // Hooks get real text from Euclid; here they get the query, so `--try-plugin <id> "<text>"` tests one.
            guard !query.isEmpty || hook.event == .open else {
                lines.append("on \(hook.event.rawValue): not run; pass sample text after the plugin name to try it")
                continue
            }
            let item = ModItem(kind: "history", title: query, url: query)
            guard let data = await attempt("on \(hook.event.rawValue)", hook.run, query: query, environment: hook.event == .choose ? item.environment : [:],
                                           timeout: PluginTiming.hook) else { continue }
            let effects = PluginEffect.parse(data)
            lines.append("on \(hook.event.rawValue) “\(query)”: " + (effects.isEmpty ? "no effects (fine: it only acts on its own)" : "\(effects.count) effect(s)"))
            for e in effects { lines.append("  " + describe(e)) }
        }
        for k in plugin.keys {
            lines.append("key: \(k.key.symbols) \(k.name)\(k.when.isEmpty ? "" : " (on \(k.when.joined(separator: ", ")))")  runs: \(k.run)  (not run here)")
        }
        let settings = plugin.environment.keys.sorted().filter { $0 != "EUCLID_PLUGIN_DIR" }
        if !settings.isEmpty { lines.append("settings: " + settings.map { "$\($0)" }.joined(separator: " ")) }
        lines.append(ok ? "OK" : "FAILED")
        return (lines.joined(separator: "\n"), ok)
    }

    static func describe(_ e: PluginEffect) -> String {
        var parts: [String] = []
        if let n = e.notice { parts.append("notice “\(n)”") }
        if let c = e.copy { parts.append("copy “\(c.count > 80 ? String(c.prefix(79)) + "…" : c)”") }
        if let o = e.open { parts.append("open \(o)") }
        if let q = e.query { parts.append("search “\(q)”") }
        return parts.joined(separator: ", ")
    }

    static func describe(_ item: PluginItem) -> String {
        var s = item.title
        if let sub = item.subtitle, !sub.isEmpty { s += " — \(sub)" }
        if let label = item.label { s += "  [\(label)]" }
        let does: String
        if let open = item.open { does = "open \(open)" }
        else if item.paste != nil { does = "paste text" }
        else if item.copy != nil { does = "copy text" }
        else if let run = item.run { does = "run \(run)" }
        else { does = "nothing (no open, paste, copy or run)" }
        s += "  ↵ \(does)"
        if item.suggest == true { s += "  (suggested)" }
        return s
    }
}

/// How long plugin commands get before they're stopped.
public enum PluginTiming {
    public static let source = Duration.seconds(30)
    /// An answer is for the query being typed; late ones are useless.
    public static let answer = Duration.seconds(2)
    /// Hooks and keys run in the background; they shouldn't linger.
    public static let hook = Duration.seconds(10)
}
