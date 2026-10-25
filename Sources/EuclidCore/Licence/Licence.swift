import CryptoKit
import Foundation

/// A licence key: `EUCLID-<payload>.<signature>`, both base64url, where the payload is JSON and
/// the signature is Ed25519 over the payload's base64url text. Checked offline against the
/// public key a release build carries; nothing phones home.
public struct Licence: Codable, Equatable, Sendable {
    public enum Edition: String, Codable, Sendable { case personal, business }

    /// Who it's for: a person or a company.
    public var name: String
    public var edition: Edition
    public var seats: Int
    /// "2026-10-24"
    public var issued: String
    /// The Paddle transaction, for support and refunds.
    public var order: String

    public init(name: String, edition: Edition, seats: Int = 1, issued: String, order: String) {
        self.name = name
        self.edition = edition
        self.seats = seats
        self.issued = issued
        self.order = order
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case malformed, badSignature

        public var description: String {
            switch self {
            case .malformed: "That doesn't look like a Euclid licence key. Paste the whole key, starting with EUCLID-."
            case .badSignature: "That licence key isn't valid. Check it was pasted in full, or email hello@lgtmworks.com."
            }
        }
    }

    static let prefix = "EUCLID-"

    /// Reads and checks a pasted key. Whitespace is ignored, so a key wrapped by an email client still works.
    public static func verify(_ key: String, publicKey: Data) throws(Problem) -> Licence {
        let compact = key.filter { !$0.isWhitespace }
        guard compact.hasPrefix(prefix) else { throw .malformed }
        let parts = compact.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Data(base64URL: parts[0]), let signature = Data(base64URL: parts[1]),
              let licence = try? JSONDecoder().decode(Licence.self, from: payload)
        else { throw .malformed }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: Data(parts[0].utf8))
        else { throw .badSignature }
        return licence
    }

    /// Issues a key. Only the seller has the private key; the app just verifies.
    public func sign(with privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(self).base64URL
        let signature = try privateKey.signature(for: Data(payload.utf8))
        return Self.prefix + payload + "." + signature.base64URL
    }
}

/// The 30-day evaluation. It never locks anything: once it's over, Euclid shows that it's
/// unregistered and reminds you now and then.
public enum Evaluation {
    /// Personal use is free while this is nil. Set it at launch: anyone who first ran Euclid
    /// before then keeps Personal free for good, and later installs get the trial.
    public static let betaEnds: Date? = nil
    public static let days = 30
    /// The gap between reminders once the trial is over.
    public static let reminderInterval: TimeInterval = 3 * 86_400

    public enum Status: Equatable, Sendable {
        case licensed(Licence)
        /// Free Personal use: installed during the beta.
        case beta
        case trial(daysLeft: Int)
        case unregistered
    }

    public static func status(_ state: LicenceState, publicKey: Data, betaEnds: Date? = betaEnds, now: Date = Date()) -> Status {
        if let key = state.key, let licence = try? Licence.verify(key, publicKey: publicKey) { return .licensed(licence) }
        if betaEnds.map({ state.firstRun < $0 }) ?? true { return .beta }
        let used = Int(now.timeIntervalSince(state.firstRun) / 86_400)
        return used < days ? .trial(daysLeft: days - max(used, 0)) : .unregistered
    }

    /// Whether to remind now: unregistered, and none shown in the last few days.
    public static func shouldRemind(_ state: LicenceState, publicKey: Data, betaEnds: Date? = betaEnds, now: Date = Date()) -> Bool {
        guard status(state, publicKey: publicKey, betaEnds: betaEnds, now: now) == .unregistered else { return false }
        guard let last = state.lastReminder else { return true }
        return now.timeIntervalSince(last) >= reminderInterval
    }
}

/// What Euclid remembers about licensing, in `licence.json` in the data folder.
public struct LicenceState: Codable, Equatable, Sendable {
    public var firstRun: Date
    public var key: String?
    public var lastReminder: Date?

    public init(firstRun: Date = Date(), key: String? = nil, lastReminder: Date? = nil) {
        self.firstRun = firstRun
        self.key = key
        self.lastReminder = lastReminder
    }

    /// The saved state, or a fresh one (trial starting now) that's saved straight away.
    public static func load(from url: URL, now: Date = Date()) -> LicenceState {
        if let data = try? Data(contentsOf: url), let state = try? decoder.decode(LicenceState.self, from: data) {
            return state
        }
        let state = LicenceState(firstRun: now)
        try? state.save(to: url)
        return state
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension Data {
    init?(base64URL text: some StringProtocol) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
