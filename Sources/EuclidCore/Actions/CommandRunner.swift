import Foundation

/// Runs an action's command safely.
///
/// The command template is trusted (the user wrote it). The query is not: it
/// can contain quotes, `$(...)`, backticks. It is therefore only ever passed
/// as a positional argument (`$1`) and environment variables, never spliced
/// into the command string:
///
///     /bin/zsh -l -c '<run>' euclid '<query>'
public enum CommandRunner {
    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public let status: Int32
        public let stderr: String
        public init(status: Int32, stderr: String) {
            self.status = status
            self.stderr = stderr
        }
        public var description: String {
            let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? "exit \(status)" : "exit \(status): \(line)"
        }
    }

    public static func environment(query: String, clip: String? = nil, pathPrefix: String? = nil,
                                   base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        if let pathPrefix { env["PATH"] = pathPrefix + ":" + (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") }
        env["EUCLID_QUERY"] = query
        env["EUCLID_QUERY_URL"] = urlEncode(query)
        if let clip { env["EUCLID_CLIP"] = clip } else { env.removeValue(forKey: "EUCLID_CLIP") }
        return env
    }

    /// Strict encoding: only RFC 3986 unreserved characters pass through,
    /// so the result is safe in any URL query position (`&`, `=`, `+`, `#` are encoded).
    public static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public static func makeProcess(shell: String, command: String, query: String, clip: String? = nil,
                                   pathPrefix: String? = nil,
                                   baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        var script = command
        var env = environment(query: query, clip: clip, pathPrefix: pathPrefix, base: baseEnvironment)
        if let pathPrefix {
            // The login profile (path_helper, ~/.zprofile) reorders PATH, so re-prefix
            // *after* it runs: scripts in the bin directory must win over same-named tools.
            env["EUCLID_BIN"] = pathPrefix
            script = "PATH=\"$EUCLID_BIN:$PATH\"\n" + command
        }
        p.arguments = ["-l", "-c", script, "euclid", query] // $0 = euclid, $1 = query
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        return p
    }

    /// Fire-and-forget. `completion` runs on an arbitrary thread when the command exits.
    public static func runInBackground(shell: String, command: String, query: String, clip: String? = nil,
                                       pathPrefix: String? = nil,
                                       baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                                       completion: @escaping @Sendable (Result<Void, Failure>) -> Void) {
        let p = makeProcess(shell: shell, command: command, query: query, clip: clip, pathPrefix: pathPrefix,
                            baseEnvironment: baseEnvironment)
        run(p, completion: completion)
    }

    /// Runs any prepared process, collecting stderr (capped) for error reporting.
    public static func run(_ p: Process, completion: @escaping @Sendable (Result<Void, Failure>) -> Void) {
        let stderr = Pipe()
        let collected = CappedBuffer(limit: 4096)
        p.standardError = stderr
        if p.standardInput == nil { p.standardInput = FileHandle.nullDevice }
        if p.standardOutput == nil { p.standardOutput = FileHandle.nullDevice }
        // Drain continuously so a chatty command can't fill the pipe and block.
        stderr.fileHandleForReading.readabilityHandler = { h in collected.append(h.availableData) }
        p.terminationHandler = { proc in
            stderr.fileHandleForReading.readabilityHandler = nil
            collected.append(stderr.fileHandleForReading.readDataToEndOfFile())
            if proc.terminationStatus == 0 {
                completion(.success(()))
            } else {
                completion(.failure(Failure(status: proc.terminationStatus, stderr: collected.string)))
            }
        }
        do {
            try p.run()
        } catch {
            let path = p.executableURL?.path ?? "?"
            completion(.failure(Failure(status: -1, stderr: "can't start \(path): \(error.localizedDescription)")))
        }
    }
}

/// Thread-safe byte buffer that keeps only the first `limit` bytes.
final class CappedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = limit - data.count
        if room > 0, !d.isEmpty { data.append(d.prefix(room)) }
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
