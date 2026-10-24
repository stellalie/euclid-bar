import Foundation
import EuclidCore
import os

/// Counts opens and picks per day for the usage receipt. Saved in the background after each change.
@MainActor
final class UsageService {
    private var log: UsageLog
    private let file: URL
    private let queue = DispatchQueue(label: "dev.euclid.usage", qos: .utility)
    private let logger = Logger(subsystem: "dev.euclid", category: "usage")

    init(file: URL) {
        self.file = file
        log = UsageLog.load(from: file)
    }

    var summary: UsageLog.Summary { log.summary() }

    func recordOpen() {
        log.recordOpen()
        save()
    }

    func recordPick(_ kind: String) {
        log.recordPick(kind)
        save()
    }

    private func save() {
        let snapshot = log, file = file, logger = logger
        queue.async {
            do { try snapshot.save(to: file) } catch {
                logger.error("can't save usage: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
