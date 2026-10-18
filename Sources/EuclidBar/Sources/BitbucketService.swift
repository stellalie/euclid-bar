import Foundation
import EuclidCore
import os

/// Your Bitbucket PRs and repos for search. Fetched in the background on launch,
/// then again when the panel opens if older than `refresh_minutes`.
/// The token comes from `token_command` (Keychain by default), never from config.toml.
@MainActor
final class BitbucketService {
    private(set) var items: [SearchItem] = []
    private var entries: [BitbucketItem] = []
    /// One-line problem for the footer (bad token, no network…), or nil.
    private(set) var problem: String?
    var onChange: (() -> Void)?

    private var settings: BitbucketSettings?
    private var shell = "/bin/zsh"
    private var environment: [String: String] = [:]
    private var lastLoad: ContinuousClock.Instant?
    private var loading = false
    private var generation = 0
    private let log = Logger(subsystem: "dev.euclid", category: "bitbucket")

    func entry(id: Int) -> BitbucketItem? { entries.indices.contains(id) ? entries[id] : nil }

    func configure(_ settings: BitbucketSettings?, shell: String, environment: [String: String]) {
        guard settings != self.settings || shell != self.shell else { return }
        self.settings = settings
        self.shell = shell
        self.environment = environment
        generation += 1
        loading = false
        guard settings != nil else {
            entries = []; items = []; problem = nil; lastLoad = nil
            onChange?()
            return
        }
        reload()
    }

    func refreshIfStale() {
        guard let settings, let last = lastLoad, ContinuousClock.now - last > .seconds(settings.refreshMinutes * 60) else { return }
        reload()
    }

    func reload() {
        guard let settings, !loading else { return }
        loading = true
        let generation = generation, shell = shell, environment = environment, log = log
        Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            let result: Result<[BitbucketItem], Error>
            do {
                let token = try Self.token(command: settings.tokenCommand, shell: shell, environment: environment)
                result = .success(try await BitbucketClient(settings: settings, token: token).fetchAll())
            } catch {
                result = .failure(error)
            }
            let elapsed = ContinuousClock.now - start
            await MainActor.run {
                guard generation == self.generation else { return } // config changed meanwhile
                self.loading = false
                self.lastLoad = .now
                switch result {
                case .success(let found):
                    self.entries = found
                    self.items = found.enumerated().map { $0.element.searchItem(id: $0.offset) }
                    self.problem = nil
                    log.notice("bitbucket: \(found.count) items in \(String(describing: elapsed), privacy: .public)")
                case .failure(let error):
                    // Keep the last good list; just say what went wrong.
                    self.problem = "⚠︎ \(error)"
                    log.error("bitbucket: \(String(describing: error), privacy: .public)")
                }
                self.onChange?()
            }
        }
    }

    /// Run `token_command` in a login shell and take its first line.
    nonisolated private static func token(command: String, shell: String, environment: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", command]
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let token = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard p.terminationStatus == 0, !token.isEmpty else {
            throw BitbucketClient.Failure(description: "Bitbucket: token_command printed no token (see [bitbucket] in config.toml)")
        }
        return token.trimmingCharacters(in: .whitespaces)
    }
}
