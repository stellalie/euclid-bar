import AppKit
import EuclidCore

/// The licence and the 30-day evaluation. Off unless the bundle carries the licence public key
/// (release builds stamp `EuclidLicencePublicKey`), so local builds never nag.
@MainActor
final class Licensing {
    static let buyURL = URL(string: "https://euclid.lgtmworks.com/#pricing")!

    private let file: URL
    private let publicKey: Data?
    private(set) var state: LicenceState

    init(file: URL) {
        self.file = file
        let key = Bundle.main.object(forInfoDictionaryKey: "EuclidLicencePublicKey") as? String ?? ""
        publicKey = Data(base64Encoded: key).flatMap { $0.count == 32 ? $0 : nil } // Ed25519
        state = publicKey == nil ? LicenceState() : LicenceState.load(from: file)
    }

    var isEnabled: Bool { publicKey != nil }

    var status: Evaluation.Status {
        guard let publicKey else { return .trial(daysLeft: Evaluation.days) }
        return Evaluation.status(state, publicKey: publicKey)
    }

    /// "Trial · 12 days left", "Ada Lovelace · Personal", "Unregistered"
    var summary: String {
        switch status {
        case .licensed(let l): "\(l.name) · \(l.edition == .business ? "Business, \(l.seats) seat\(l.seats == 1 ? "" : "s")" : "Personal")"
        case .beta: "Free beta · Personal"
        case .trial(let days): "Trial · \(days) day\(days == 1 ? "" : "s") left"
        case .unregistered: "Unregistered"
        }
    }

    var isLicensed: Bool { if case .licensed = status { true } else { false } }

    /// Checks and saves a pasted key; returns what's wrong with it, or nil.
    func enter(_ key: String) -> String? {
        guard let publicKey else { return "This build doesn't check licences." }
        do {
            _ = try Licence.verify(key, publicKey: publicKey)
        } catch {
            return error.description
        }
        state.key = key.filter { !$0.isWhitespace }
        return save()
    }

    /// The panel's footer nudge, at most every few days once the trial is over. Never modal:
    /// it can't steal a keystroke, and Euclid keeps working.
    /// `receipt` is what the last 30 days looked like, so the value is right there when you decide.
    func takeReminder(receipt: String?) -> String? {
        guard let publicKey, Evaluation.shouldRemind(state, publicKey: publicKey) else { return nil }
        state.lastReminder = Date()
        _ = save()
        guard let receipt else { return "Your 30-day trial is over. Euclid keeps working; search “licence” to buy or register." }
        return "Trial over: search “licence” to buy. Your 30 days: \(receipt)"
    }

    private func save() -> String? {
        do { try state.save(to: file) } catch { return "Couldn't save the licence: \(error.localizedDescription)" }
        return nil
    }

    func openBuyPage() { NSWorkspace.shared.open(Self.buyURL) }

    /// Asks for a key. Returns true when a valid one was saved.
    @discardableResult
    func promptForKey() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Enter your Euclid licence key"
        alert.informativeText = "Paste the key from your purchase email. It starts with EUCLID-."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        field.placeholderString = "EUCLID-…"
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        alert.accessoryView = field
        alert.addButton(withTitle: "Register")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        while alert.runModal() == .alertFirstButtonReturn {
            guard let problem = enter(field.stringValue) else {
                let done = NSAlert()
                done.messageText = "Thank you for buying Euclid"
                done.informativeText = "Registered to \(summary)."
                done.runModal()
                return true
            }
            alert.informativeText = problem
        }
        return false
    }
}
