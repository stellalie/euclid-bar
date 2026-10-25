import Foundation

/// Runs a plugin's command and returns what it printed.
///
/// Same rules as actions (`CommandRunner`): a login shell, the query only ever as `$1`,
/// `<config>/bin` first on PATH. It also runs in the plugin's folder with the plugin's
/// environment, and is killed after `timeout` or when the calling task is cancelled.
public enum PluginRunner {
    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Output past this is dropped.
    static let maxOutput = 4 << 20

    public static func output(of command: String, plugin: Plugin, query: String = "", shell: String,
                              pathPrefix: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                              timeout: Duration) async throws -> Data {
        // `"$@"`: the text reaches the command as its argument, so `run = "./tz.sh"` sees it as $1.
        let line = query.isEmpty ? command : command + #" "$@""#
        let p = CommandRunner.makeProcess(shell: shell, command: line, query: query, pathPrefix: pathPrefix,
                                          directory: plugin.directory,
                                          baseEnvironment: environment.merging(plugin.environment) { $1 })
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let stdout = CappedBuffer(limit: maxOutput), stderr = CappedBuffer(limit: 4096)
        out.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }
        let stopped = Flag()
        @Sendable func stop() {
            guard p.isRunning, !stopped.isSet else { return }
            stopped.set()
            // SIGKILL: a late plugin is just dropped, and SIGTERM can be ignored (inherited SIG_IGN).
            // The shell's children (a script, `sleep`) would keep the pipes open: stop them too.
            if let pkill = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-KILL", "-P", "\(p.processIdentifier)"]) {
                pkill.waitUntilExit()
            }
            kill(p.processIdentifier, SIGKILL)
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    if !stopped.isSet { // a stopped run's leftovers could block the read; they're unused anyway
                        stdout.append(out.fileHandleForReading.readDataToEndOfFile())
                        stderr.append(err.fileHandleForReading.readDataToEndOfFile())
                    }
                    done.resume(returning: proc.terminationStatus)
                }
                do { try p.run() } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    done.resume(throwing: Failure("can't start \(shell): \(error.localizedDescription)"))
                    return
                }
                let (s, atto) = timeout.components
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(s) + Double(atto) / 1e18) { stop() }
            }
        } onCancel: {
            stop()
        }

        try Task.checkCancellation()
        if stopped.isSet { throw Failure("took longer than \(timeout.formatted(.units(allowed: [.seconds, .milliseconds])))") }
        guard status == 0 else {
            let line = stderr.string.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            throw Failure(line.isEmpty ? "exit \(status)" : "exit \(status): \(line)")
        }
        return stdout.bytes
    }
}

/// A thread-safe one-way switch.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
