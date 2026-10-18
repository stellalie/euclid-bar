import Foundation

/// Developer conversions answered inline, like the calculator:
///
///     1697040000            → 2023-10-11 16:00:00 (epoch seconds or ms → date)
///     2023-10-11T16:00:00Z  → 1697040000
///     now                   → current epoch
///     uuid                  → a fresh UUID
///     b64 hello             → aGVsbG8=          aGVsbG8gd29ybGQ= → hello world
///     {"a":1}               → pretty / minified JSON
///     a%20b                 → a b               urlencode a b → a%20b
///     #ff8800 / rgb(…)      → the other notation, with a swatch
///     eyJhbGciOi…           → decoded JWT header and payload
///
/// Each answer only shows when the input clearly is that thing, so normal
/// searches never see them.
public enum DevTransforms {
    public struct Result: Equatable, Sendable {
        /// What the row shows (one line).
        public let display: String
        /// What ↵ copies, and what the preview shows in full.
        public let value: String
        /// The trailing label, e.g. "Epoch → Date".
        public let label: String
        /// sRGB 0–1, for a colour swatch.
        public var color: RGB?

        public init(display: String, value: String, label: String, color: RGB? = nil) {
            self.display = display
            self.value = value
            self.label = label
            self.color = color
        }
    }

    public struct RGB: Equatable, Sendable {
        public let r: Double, g: Double, b: Double
    }

    public static func evaluate(_ input: String, now: Date = Date(), timeZone: TimeZone = .current) -> [Result] {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.utf8.count <= 100_000 else { return [] }
        let lower = s.lowercased()

        switch lower {
        case "uuid", "guid":
            let u = UUID().uuidString.lowercased()
            return [Result(display: u, value: u, label: "UUID")]
        case "now", "epoch", "timestamp", "unix":
            let e = String(Int(now.timeIntervalSince1970))
            return [Result(display: e, value: e, label: "Epoch now"),
                    Result(display: iso(now, timeZone), value: iso(now, timeZone), label: "Date now")]
        default: break
        }

        if let rest = command(s, ["b64 ", "base64 "]) {
            let e = Data(rest.utf8).base64EncodedString()
            return [Result(display: e, value: e, label: "Base64 encode")]
        }
        if let rest = command(s, ["b64d ", "base64d "]), let d = base64Decode(rest) {
            return [Result(display: firstLine(d), value: d, label: "Base64 decode")]
        }
        if let rest = command(s, ["urlencode ", "urlenc "]) {
            let e = rest.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? rest
            return [Result(display: e, value: e, label: "URL encode")]
        }

        var out: [Result] = []
        out += epoch(s, timeZone: timeZone)
        out += date(s)
        out += json(s)
        out += jwt(s)
        out += color(lower)
        if out.isEmpty { out += urlDecode(s) }
        if out.isEmpty { out += autoBase64(s) }
        return out
    }

    // MARK: - Pieces

    private static func command(_ s: String, _ prefixes: [String]) -> String? {
        for p in prefixes where s.lowercased().hasPrefix(p) {
            let rest = String(s.dropFirst(p.count))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    static func iso(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f.string(from: date)
    }

    /// 10 digits = seconds, 13 = milliseconds, between 2001 and 2100.
    static func epoch(_ s: String, timeZone: TimeZone) -> [Result] {
        guard s.count == 10 || s.count == 13, s.allSatisfy(\.isASCII), let n = Int64(s) else { return [] }
        let seconds = s.count == 13 ? Double(n) / 1000 : Double(n)
        guard (978_307_200...4_102_444_800).contains(seconds) else { return [] }
        let d = iso(Date(timeIntervalSince1970: seconds), timeZone)
        let utc = iso(Date(timeIntervalSince1970: seconds), TimeZone(identifier: "UTC")!)
        var out = [Result(display: d, value: d, label: s.count == 13 ? "Epoch ms → Date" : "Epoch → Date")]
        if timeZone.secondsFromGMT() != 0 { out.append(Result(display: utc, value: utc, label: "Epoch → UTC")) }
        return out
    }

    /// An ISO-8601 date or date-time → epoch seconds.
    static func date(_ s: String) -> [Result] {
        guard s.count >= 10, s.count <= 35, s.first?.isNumber == true, s.contains("-") else { return [] }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        guard let d = full.date(from: s) ?? frac.date(from: s) ?? (s.count == 10 ? day.date(from: s) : nil) else { return [] }
        let e = String(Int(d.timeIntervalSince1970))
        return [Result(display: e, value: e, label: "Date → Epoch")]
    }

    static func json(_ s: String) -> [Result] {
        guard let f = s.first, f == "{" || f == "[", s.count >= 2,
              let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let mini = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
              let p = String(data: pretty, encoding: .utf8), let m = String(data: mini, encoding: .utf8) else { return [] }
        let lines = p.split(separator: "\n").count
        return [Result(display: "Pretty JSON · \(lines) lines", value: p, label: "JSON"),
                Result(display: m, value: m, label: "JSON minified")]
    }

    /// `header.payload.signature`, each base64url; header and payload are JSON.
    static func jwt(_ s: String) -> [Result] {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, s.hasPrefix("eyJ"), !s.contains(" "),
              let header = base64Decode(String(parts[0])), let payload = base64Decode(String(parts[1])),
              let h = prettyJSON(header), let p = prettyJSON(payload) else { return [] }
        var display = "JWT"
        if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
            if let sub = obj["sub"] { display += " · sub \(sub)" }
            if let exp = obj["exp"] as? Double {
                let date = Date(timeIntervalSince1970: exp)
                display += date < Date() ? " · expired \(RelativeAge.short(date))" : " · expires \(iso(date, .current))"
            }
        }
        return [Result(display: display, value: "// header\n\(h)\n\n// payload\n\(p)", label: "JWT decode")]
    }

    private static func prettyJSON(_ s: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// `#rgb`, `#rrggbb` → `rgb(…)`; `rgb(r, g, b)` → `#rrggbb`.
    static func color(_ s: String) -> [Result] {
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit), let _ = Int(hex, radix: 16) else { return [] }
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            let v = Int(hex, radix: 16)!
            let r = v >> 16 & 0xFF, g = v >> 8 & 0xFF, b = v & 0xFF
            let text = "rgb(\(r), \(g), \(b))"
            return [Result(display: text, value: text, label: "Hex → RGB", color: RGB(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255))]
        }
        guard s.hasPrefix("rgb(") || s.hasPrefix("rgb "), let open = s.firstIndex(where: { $0 == "(" || $0 == " " }) else { return [] }
        let inner = s[s.index(after: open)...].replacingOccurrences(of: ")", with: "")
        let nums = inner.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        guard nums.count == 3, nums.allSatisfy({ (0...255).contains($0) }) else { return [] }
        let text = String(format: "#%02x%02x%02x", nums[0], nums[1], nums[2])
        return [Result(display: text, value: text, label: "RGB → Hex",
                       color: RGB(r: Double(nums[0]) / 255, g: Double(nums[1]) / 255, b: Double(nums[2]) / 255))]
    }

    static func urlDecode(_ s: String) -> [Result] {
        guard s.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil,
              let d = s.removingPercentEncoding, d != s else { return [] }
        return [Result(display: firstLine(d), value: d, label: "URL decode")]
    }

    /// Only for strings that look deliberately encoded: 16+ base64 characters
    /// that decode to readable text.
    static func autoBase64(_ s: String) -> [Result] {
        guard s.count >= 16, !s.contains(" "),
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=-_".contains($0)) }),
              s.contains(where: \.isNumber) || s.hasSuffix("=") || s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase),
              let d = base64Decode(s) else { return [] }
        return [Result(display: firstLine(d), value: d, label: "Base64 decode")]
    }

    /// Standard or URL-safe base64, padded or not, to printable UTF-8.
    static func base64Decode(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b), !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        let printable = text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || "\n\r\t".unicodeScalars.contains($0) }
        return printable ? text : nil
    }

    private static func firstLine(_ s: String) -> String {
        String(s.prefix(300).split(whereSeparator: \.isNewline).first ?? "")
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
