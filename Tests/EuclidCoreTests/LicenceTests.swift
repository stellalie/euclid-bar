import CryptoKit
import Foundation
import Testing
@testable import EuclidCore

@Suite struct LicenceTests {
    let seller = Curve25519.Signing.PrivateKey()
    var publicKey: Data { seller.publicKey.rawRepresentation }
    let ada = Licence(name: "Ada Lovelace", edition: .personal, issued: "2026-10-24", order: "txn_01")

    @Test func roundTrips() throws {
        let key = try ada.sign(with: seller)
        #expect(key.hasPrefix("EUCLID-"))
        #expect(try Licence.verify(key, publicKey: publicKey) == ada)
    }

    @Test func toleratesWrappedPaste() throws {
        let key = try ada.sign(with: seller)
        let wrapped = "  " + key.enumerated().map { $0.offset % 40 == 39 ? "\($0.element)\n" : "\($0.element)" }.joined() + "\n"
        #expect(try Licence.verify(wrapped, publicKey: publicKey) == ada)
    }

    @Test func rejectsTamperingAndJunk() throws {
        let key = try ada.sign(with: seller)
        let forged = try Licence(name: "Mallory", edition: .business, seats: 500, issued: "2026-10-24", order: "x")
            .sign(with: Curve25519.Signing.PrivateKey())
        #expect(throws: Licence.Problem.badSignature) { try Licence.verify(forged, publicKey: publicKey) }

        // Same signature, edited payload.
        let sig = key.split(separator: ".")[1]
        let edited = try JSONEncoder().encode(Licence(name: "Ada", edition: .business, seats: 99, issued: "2026-10-24", order: "txn_01"))
        #expect(throws: Licence.Problem.badSignature) {
            try Licence.verify("EUCLID-\(edited.base64URL).\(sig)", publicKey: publicKey)
        }
        for junk in ["", "hello", "EUCLID-", "EUCLID-abc", "EUCLID-a.b.c", String(key.dropFirst(7))] {
            #expect(throws: Licence.Problem.malformed) { try Licence.verify(junk, publicKey: publicKey) }
        }
    }

    /// A key from the licence server (server/licences), signed with its test-only key, verifies here.
    @Test func acceptsKeysFromTheLicenceServer() throws {
        let key = "EUCLID-eyJlZGl0aW9uIjoiYnVzaW5lc3MiLCJpc3N1ZWQiOiIyMDI2LTEwLTMxIiwibmFtZSI6IkFkYSBMb3ZlbGFjZSIsIm9yZGVyIjoidHhuXzAxbTY4NmtiOWJiZDFwdDZleGJ6NnNhcXM4Iiwic2VhdHMiOjN9.MFWkRgdl0xOzQHKv2KEvlJnLhSi6WPRx8ML6L7tdeNPH_-TFn-YV7l-5fRcj-Li9ft2gTux6kWPOWYC0xmv5Dg"
        let serverPublicKey = try #require(Data(base64URL: "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"))
        let licence = try Licence.verify(key, publicKey: serverPublicKey)
        #expect(licence == Licence(name: "Ada Lovelace", edition: .business, seats: 3, issued: "2026-10-31",
                                   order: "txn_01m686kb9bbd1pt6exbz6saqs8"))
    }

    @Test func trialRunsThirtyDaysThenNeverLocks() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 86_400
        let state = LicenceState(firstRun: start)
        #expect(Evaluation.status(state, publicKey: publicKey, betaEnds: start, now: start) == .trial(daysLeft: 30))
        #expect(Evaluation.status(state, publicKey: publicKey, betaEnds: start, now: start + 29.5 * day) == .trial(daysLeft: 1))
        #expect(Evaluation.status(state, publicKey: publicKey, betaEnds: start, now: start + 30 * day) == .unregistered)
        #expect(Evaluation.status(state, publicKey: publicKey, betaEnds: start, now: start - day) == .trial(daysLeft: 30), "clock moved back")

        var licensed = state
        licensed.key = try ada.sign(with: seller)
        #expect(Evaluation.status(licensed, publicKey: publicKey, betaEnds: start, now: start + 400 * day) == .licensed(ada))
        licensed.key = "EUCLID-junk"
        #expect(Evaluation.status(licensed, publicKey: publicKey, betaEnds: start, now: start + 31 * day) == .unregistered)
    }

    @Test func betaInstallsStayFree() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 86_400
        let early = LicenceState(firstRun: start)
        #expect(Evaluation.status(early, publicKey: publicKey, betaEnds: nil, now: start + 90 * day) == .free, "free while betaEnds is nil")
        let launch = start + 60 * day
        #expect(Evaluation.status(early, publicKey: publicKey, betaEnds: launch, now: start + 400 * day) == .free, "early installs keep it")
        #expect(!Evaluation.shouldRemind(early, publicKey: publicKey, betaEnds: launch, now: start + 400 * day))

        let late = LicenceState(firstRun: launch + day)
        #expect(Evaluation.status(late, publicKey: publicKey, betaEnds: launch, now: launch + 2 * day) == .trial(daysLeft: 29))

        var bought = early
        bought.key = try ada.sign(with: seller)
        #expect(Evaluation.status(bought, publicKey: publicKey, betaEnds: nil) == .licensed(ada), "a key still wins")
    }

    @Test func remindsEveryFewDaysOnceUnregistered() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 86_400
        var state = LicenceState(firstRun: start)
        #expect(!Evaluation.shouldRemind(state, publicKey: publicKey, betaEnds: start, now: start + 10 * day), "still in trial")
        #expect(Evaluation.shouldRemind(state, publicKey: publicKey, betaEnds: start, now: start + 31 * day))
        state.lastReminder = start + 31 * day
        #expect(!Evaluation.shouldRemind(state, publicKey: publicKey, betaEnds: start, now: start + 33 * day))
        #expect(Evaluation.shouldRemind(state, publicKey: publicKey, betaEnds: start, now: start + 34 * day))
    }

    @Test func stateIsSavedOnFirstLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-licence-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = LicenceState.load(from: url, now: now)
        #expect(first == LicenceState(firstRun: now))
        // A later launch keeps the original start, so the trial doesn't restart.
        #expect(LicenceState.load(from: url, now: now + 86_400 * 5) == first)

        var saved = first
        saved.key = "EUCLID-x.y"
        try saved.save(to: url)
        #expect(LicenceState.load(from: url) == saved)
    }
}
