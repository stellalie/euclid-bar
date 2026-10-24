import CryptoKit
import EuclidCore
import Foundation

/// Seller-side commands for licence keys (see docs/RELEASING.md). Harmless in the shipped app:
/// issuing needs the private key, which only the seller has.
enum LicenceTool {
    /// `euclid-bar --licence-keygen`: a new signing key pair, both base64.
    static func keygen() -> Int32 {
        let key = Curve25519.Signing.PrivateKey()
        print("LICENCE_PUBLIC_KEY=\(key.publicKey.rawRepresentation.base64EncodedString())")
        print("LICENCE_PRIVATE_KEY=\(key.rawRepresentation.base64EncodedString())")
        print("Keep the private key secret (a password manager). The public key goes in the repo variable.")
        return 0
    }

    /// `LICENCE_PRIVATE_KEY=… euclid-bar --issue-licence "Name" personal|business [seats] [order]`
    static func issue(_ args: [String]) -> Int32 {
        guard let secret = ProcessInfo.processInfo.environment["LICENCE_PRIVATE_KEY"],
              let raw = Data(base64Encoded: secret), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else { print("error: set LICENCE_PRIVATE_KEY (from --licence-keygen)"); return 2 }
        guard args.count >= 2, let edition = Licence.Edition(rawValue: args[1]) else {
            print("usage: euclid-bar --issue-licence \"Name\" personal|business [seats] [order]")
            return 2
        }
        let seats = args.count > 2 ? Int(args[2]) ?? 0 : 1
        guard seats > 0 else { print("error: seats must be a whole number above 0"); return 2 }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withFullDate])
        let licence = Licence(name: args[0], edition: edition, seats: seats, issued: day, order: args.count > 3 ? args[3] : "")
        do { print(try licence.sign(with: key)) } catch { print("error: \(error)"); return 1 }
        return 0
    }
}
