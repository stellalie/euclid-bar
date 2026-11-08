import Foundation

/// Runs a plugin's command and returns what it printed.
///
/// Same rules as actions (`CommandRunner`): a login shell, the query only ever as `$1`,
/// `<config>/bin` first on PATH. It also runs in the plugin's folder with the plugin's
/// environment, and is killed after `timeout` or when the calling task is cancelled.
public enum PluginRunner {
    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String
        /// The command the shell couldn't find (`gh`), when that's why it failed.
        public var missingCommand: String?
        /// `keepRunning` and it outlived the timeout: it goes on, its output unread.
        public var stillRunning = false
        public init(_ description: String, missingCommand: String? = nil) {
            self.description = description
            self.missingCommand = missingCommand
        }
    }

    /// The command a shell says it couldn't find: zsh's "zsh:1: command not found: gh",
    /// bash's "items.sh: line 3: gh: command not found", sh's "gh: not found".
    public static func missingCommand(in stderr: String) -> String? {
        for line in stderr.split(whereSeparator: \.isNewline).map(String.init) {
            if let r = line.range(of: "command not found: ") {
                let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
            for marker in [": command not found", ": not found"] where line.hasSuffix(marker) {
                let head = line.dropLast(marker.count)
                let name = head.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !name.isEmpty, !name.contains(" ") { return name }
            }
        }
        return nil
    }

    /// Output past this is dropped.
    static let maxOutput = 4 << 20

    /// `arguments` (an item's fields) replace the query as `$1`, `$2`…
    /// `keepRunning`: past `timeout`, stop waiting (throws `stillRunning`) but don't kill it:
    /// an item's `run` may start something long on purpose.
    public static func output(of command: String, plugin: Plugin, query: String = "", arguments: [String]? = nil, shell: String,
                              pathPrefix: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                              timeout: Duration, keepRunning: Bool = false) async throws -> Data {
        let args = arguments ?? (query.isEmpty ? [] : [query])
        // `"$@"`: the text reaches the command as its argument, so `run = "./tz.sh"` sees it as $1.
        let line = args.isEmpty ? command : command + #" "$@""#
        var env = environment.merging(plugin.environment) { $1 }
        for (i, a) in (arguments ?? []).enumerated() { env["EUCLID_ARG_\(i + 1)"] = a }
        let p = CommandRunner.makeProcess(shell: shell, command: line, query: query, arguments: args, pathPrefix: pathPrefix,
                                          directory: plugin.directory, baseEnvironment: env)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let stdout = CappedBuffer(limit: maxOutput), stderr = CappedBuffer(limit: 4096)
        // Read both pipes to the end on their own threads (so a big output never fills a pipe and
        // stalls the script), and return only once both reads are done. A readabilityHandler
        // could still be appending its last chunk after exit, which lost the whole output.
        let reads = DispatchGroup()
        @Sendable func drain(_ pipe: Pipe, into buffer: CappedBuffer) {
            reads.enter()
            DispatchQueue.global().async {
                while case let d = pipe.fileHandleForReading.availableData, !d.isEmpty { buffer.append(d) }
                reads.leave()
            }
        }
        let stopped = Flag(), detached = Flag(), resumed = Flag()
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
                @Sendable func finish(_ result: Result<Int32, Error>) {
                    guard !resumed.testAndSet() else { return }
                    done.resume(with: result)
                }
                p.terminationHandler = { proc in
                    let status = proc.terminationStatus
                    // A stopped run's leftovers could keep the pipes open; its output is unused anyway.
                    if stopped.isSet { finish(.success(status)); return }
                    reads.notify(queue: .global()) { finish(.success(status)) }
                }
                // Reading starts first, so a run that ends at once is still waited for.
                drain(out, into: stdout)
                drain(err, into: stderr)
                do { try p.run() } catch {
                    try? out.fileHandleForWriting.close() // ends the reads
                    try? err.fileHandleForWriting.close()
                    finish(.failure(Failure("can't start \(shell): \(error.localizedDescription)")))
                    return
                }
                let (s, atto) = timeout.components
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(s) + Double(atto) / 1e18) {
                    if keepRunning {
                        detached.set()
                        finish(.success(-1))
                    } else {
                        stop()
                    }
                }
            }
        } onCancel: {
            stop()
        }

        try Task.checkCancellation()
        if detached.isSet {
            var f = Failure("still running after \(timeout.formatted(.units(allowed: [.seconds, .milliseconds])))")
            f.stillRunning = true
            throw f
        }
        if stopped.isSet { throw Failure("took longer than \(timeout.formatted(.units(allowed: [.seconds, .milliseconds])))") }
        guard status == 0 else {
            if status == 127, let missing = missingCommand(in: stderr.string) {
                throw Failure("needs `\(missing)`, which isn't installed or isn't on PATH", missingCommand: missing)
            }
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
    /// Sets it; true if it was already set.
    func testAndSet() -> Bool { lock.lock(); defer { lock.unlock() }; let was = value; value = true; return was }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
