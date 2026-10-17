import Foundation
import EuclidCore
import os

/// Remembers what you pick for what you type, so it ranks first next time.
@MainActor
final class RankingService {
    private var model = Frecency()
    private let store: FrecencyStore?
    private let queue = DispatchQueue(label: "dev.euclid.ranking", qos: .utility)
    private let log = Logger(subsystem: "dev.euclid", category: "ranking")

    init(databaseURL: URL) {
        do {
            let store = try FrecencyStore(path: databaseURL.path)
            model = try store.load()
            self.store = store
        } catch {
            log.error("ranking store unavailable: \(error.localizedDescription, privacy: .public)")
            store = nil
        }
    }

    func bonuses(for query: String) -> [String: Int] { model.bonuses(for: query) }

    func top(_ n: Int) -> [String] { model.top(n) }

    func record(query: String, key: String) {
        let pick = model.record(query: query, key: key)
        guard let store else { return }
        queue.async { [log] in
            do { try store.save(pick) } catch {
                log.error("can't save pick: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
