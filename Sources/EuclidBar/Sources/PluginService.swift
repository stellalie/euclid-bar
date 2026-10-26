import Foundation
import EuclidCore
import os

/// Runs plugins: sources and badges in the background (on load, then when the panel opens
/// and they're older than `refresh_minutes`), answers for the query being typed.
@MainActor
final class PluginService {
    struct Entry {
        let pluginID: String
        let pluginName: String
        let item: PluginItem
    }

    struct BadgeState: Equatable {
        let pluginID: String
        let text: String
        let icon: String?
        let hasClick: Bool
    }

    /// Every source's items, for search; `SearchItem.id` indexes `entries`.
    private(set) var items: [SearchItem] = []
    private(set) var entries: [Entry] = []
    /// Badges with text, in plugin order.
    private(set) var badges: [BadgeState] = []
    /// One-line problem for the footer, or nil.
    var problem: String? { problems.sorted { $0.key < $1.key }.first.map { "⚠︎ \($0.value)" } }
    var onChange: (() -> Void)?
    /// Answers for `query` arrived (possibly none).
    var onAnswers: ((_ query: String, [Entry]) -> Void)?
    /// A hook or key printed effects (or failed: a notice saying so).
    var onEffects: ((_ pluginName: String, [PluginEffect]) -> Void)?
    /// Every `[[key]]`, in plugin order.
    var keys: [(pluginID: String, key: Plugin.Key)] { plugins.flatMap { p in p.keys.map { (p.id, $0) } } }
    /// Whether anything listens for `event`, so callers can skip building its input.
    func hasHooks(for event: Plugin.Event) -> Bool { plugins.contains { $0.hooks.contains { $0.event == event } } }

    private(set) var plugins: [Plugin] = []
    private var shell = "/bin/zsh"
    private var environment: [String: String] = [:]
    private let binDirectory: String
    private var sourceItems: [String: [PluginItem]] = [:]
    private var badgeText: [String: String] = [:]
    private var problems: [String: String] = [:]
    private var lastRun: [String: ContinuousClock.Instant] = [:]
    private var running: Set<String> = []
    private var generation = 0
    private var answerTask: Task<Void, Never>?
    /// Hooks still running; one run of each at a time.
    private var hooksRunning: Set<String> = []
    private let log = Logger(subsystem: "dev.euclid", category: "plugins")

    init(binDirectory: String) {
        self.binDirectory = binDirectory
    }

    func entry(id: Int) -> Entry? { entries.indices.contains(id) ? entries[id] : nil }
    func plugin(id: String) -> Plugin? { plugins.first { $0.id == id } }

    /// New config: drop what no longer exists, rerun what changed.
    func configure(_ plugins: [Plugin], shell: String, environment: [String: String]) {
        guard plugins != self.plugins || shell != self.shell || environment != self.environment else { return }
        let old = Dictionary(self.plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.plugins = plugins
        self.shell = shell
        self.environment = environment
        generation += 1
        running = []
        hooksRunning = []
        let ids = Set(plugins.map(\.id))
        sourceItems = sourceItems.filter { ids.contains($0.key) }
        badgeText = badgeText.filter { ids.contains($0.key) }
        problems = [:]
        for p in plugins where old[p.id] != p { // changed or new: run now
            lastRun = lastRun.filter { !$0.key.hasPrefix(p.id + "/") }
        }
        rebuild()
        refreshIfStale()
    }

    /// Rerun sources and badges older than their `refresh_minutes`.
    func refreshIfStale() {
        for p in plugins {
            if let s = p.source { run(p, part: "source", command: s.run, every: s.refreshMinutes) }
            if let b = p.badge { run(p, part: "badge", command: b.run, every: b.refreshMinutes) }
        }
    }

    private func run(_ plugin: Plugin, part: String, command: String, every minutes: Int) {
        let key = "\(plugin.id)/\(part)"
        if let last = lastRun[key], ContinuousClock.now - last < .seconds(minutes * 60) { return }
        guard running.insert(key).inserted else { return }
        lastRun[key] = .now
        let generation = generation, shell = shell, env = mergedEnvironment, bin = binDirectory, log = log
        Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            let result: Result<Data, Error>
            do {
                result = .success(try await PluginRunner.output(of: command, plugin: plugin, shell: shell, pathPrefix: bin,
                                                                environment: env, timeout: PluginTiming.source))
            } catch {
                result = .failure(error)
            }
            let elapsed = ContinuousClock.now - start
            await MainActor.run {
                guard generation == self.generation else { return }
                self.running.remove(key)
                switch result {
                case .success(let data) where part == "badge":
                    self.badgeText[plugin.id] = Plugin.Badge.text(from: data)
                    self.problems[key] = nil
                case .success(let data):
                    let (found, bad) = PluginOutput.parse(data)
                    self.sourceItems[plugin.id] = found
                    self.problems[key] = bad.first.map { "\(plugin.name): \($0)" }
                    log.notice("\(plugin.id, privacy: .public): \(found.count) items in \(String(describing: elapsed), privacy: .public)")
                case .failure(let error):
                    // Keep the last good items; say what went wrong (in search too, if there's nothing to show).
                    self.problems[key] = "\(plugin.name): \(error)"
                    if part == "source", self.sourceItems[plugin.id]?.contains(where: { $0.id != "problem:\(plugin.id)" }) != true {
                        self.sourceItems[plugin.id] = [.failed(plugin, error)]
                    }
                    log.error("\(key, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                self.rebuild()
                self.onChange?()
            }
        }
    }

    private func rebuild() {
        entries = plugins.flatMap { p in (sourceItems[p.id] ?? []).map { Entry(pluginID: p.id, pluginName: p.name, item: $0) } }
        items = entries.enumerated().map { $0.element.item.searchItem(id: $0.offset) }
        badges = plugins.compactMap { p in
            guard let b = p.badge, let text = badgeText[p.id] else { return nil }
            return BadgeState(pluginID: p.id, text: text, icon: b.icon, hasClick: b.click != nil)
        }
    }

    /// Run the answers whose prefix or regex matches, after a short pause in typing.
    /// Earlier, unfinished answers are stopped.
    func answer(_ query: String) {
        answerTask?.cancel()
        let matching = plugins.compactMap { p in p.answer.flatMap { a in a.input(for: query).map { (p, a, $0) } } }
        guard !matching.isEmpty else {
            answerTask = nil
            onAnswers?(query, [])
            return
        }
        let shell = shell, env = mergedEnvironment, bin = binDirectory
        answerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = await withTaskGroup(of: (Int, [Entry], String?).self) { group in
                for (i, (plugin, answer, input)) in matching.enumerated() {
                    group.addTask {
                        do {
                            let data = try await PluginRunner.output(of: answer.run, plugin: plugin, query: input, shell: shell,
                                                                     pathPrefix: bin, environment: env, timeout: PluginTiming.answer)
                            let items = PluginOutput.parse(data).items
                            return (i, items.map { Entry(pluginID: plugin.id, pluginName: plugin.name, item: $0) }, nil)
                        } catch {
                            return (i, [], "\(plugin.name): \(error)")
                        }
                    }
                }
                var out: [(Int, [Entry], String?)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }
            }
            guard !Task.isCancelled, let self else { return }
            for (_, _, failure) in results { if let failure { self.log.error("answer: \(failure, privacy: .public)") } }
            self.onAnswers?(query, results.flatMap(\.1))
        }
    }

    func cancelAnswers() {
        answerTask?.cancel()
        answerTask = nil
    }

    /// Run the hooks for `event` in the background, with `input` as `$1`.
    func fire(_ event: Plugin.Event, input: String, environment extra: [String: String] = [:]) {
        for p in plugins {
            for (i, hook) in p.hooks.enumerated() where hook.event == event {
                let key = "\(p.id)#\(i)"
                guard hooksRunning.insert(key).inserted else { continue } // the last one is still going
                execute(hook.run, plugin: p, input: input, environment: extra, label: "\(p.name) (on \(event.rawValue))",
                        timeout: PluginTiming.hook, mayPaste: false) { [weak self] in
                    self?.hooksRunning.remove(key)
                }
            }
        }
    }

    /// A `[[key]]` on the selected result: `$1` is its URL, path or text.
    func runKey(_ key: Plugin.Key, pluginID: String, item: ModItem, query: String) {
        guard let p = plugin(id: pluginID) else { return }
        execute(key.run, plugin: p, input: item.value, environment: item.environment.merging(["EUCLID_SEARCH": query]) { $1 },
                label: key.name, timeout: PluginTiming.key, mayPaste: true, done: nil)
    }

    private func execute(_ command: String, plugin p: Plugin, input: String, environment extra: [String: String],
                         label: String, timeout: Duration, mayPaste: Bool, done: (@MainActor @Sendable () -> Void)?) {
        let shell = shell, env = mergedEnvironment.merging(extra) { $1 }, bin = binDirectory, log = log
        Task.detached(priority: .userInitiated) {
            let result: Result<Data, Error>
            do {
                result = .success(try await PluginRunner.output(of: command, plugin: p, query: input, shell: shell, pathPrefix: bin,
                                                                environment: env, timeout: timeout))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                done?()
                switch result {
                case .success(let data):
                    var effects = PluginEffect.parse(data)
                    // Only a key you pressed may type into your app; a hook fires on its own.
                    if !mayPaste { effects = effects.map { var e = $0; e.paste = nil; return e } }
                    if !effects.isEmpty { self.onEffects?(p.name, effects) }
                case .failure(let error):
                    log.error("\(label, privacy: .public): \(String(describing: error), privacy: .public)")
                    self.onEffects?(p.name, [PluginEffect(notice: "⚠︎ \(label): \(error)")])
                }
            }
        }
    }

    /// `run` on an item, `click` on a badge, both in the plugin's folder.
    func runCommand(_ command: String, pluginID: String, completion: @escaping @Sendable (Result<Void, CommandRunner.Failure>) -> Void) {
        guard let p = plugin(id: pluginID) else { return }
        CommandRunner.runInBackground(shell: shell, command: command, query: "", pathPrefix: binDirectory,
                                      directory: p.directory, baseEnvironment: mergedEnvironment.merging(p.environment) { $1 },
                                      completion: completion)
    }

    private var mergedEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.merging(environment) { $1 }
    }
}
