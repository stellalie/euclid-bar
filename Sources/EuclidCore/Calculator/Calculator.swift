import Foundation

/// Inline calculator: arithmetic and unit conversion, typed straight into the search box.
///
///     12 * (3 + 4)        2^10        sqrt(2)        20% of 80
///     1.5 gb in mb        10 km to mi        72 f in c        90 min in h
///
/// Only answers queries that are clearly math (an operator, a function call or
/// "<value> <unit> in <unit>"), so typing a name or a plain number never shows it.
public enum Calculator {
    public struct Result: Equatable, Sendable {
        public let value: Double
        public let unit: String?
        /// What you copy or paste: plain digits, no grouping.
        public var text: String { Calculator.format(value, grouping: false) + (unit.map { " \($0)" } ?? "") }
        /// What the panel shows.
        public var display: String { Calculator.format(value, grouping: true) + (unit.map { " \($0)" } ?? "") }
    }

    public static func evaluate(_ input: String) -> Result? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 200 else { return nil }
        if let r = convert(s) { return r }
        guard looksLikeMath(s) else { return nil }
        var p = Parser(s)
        guard let v = p.parseAll(), v.isFinite else { return nil }
        return Result(value: v, unit: nil)
    }

    // MARK: - Units

    private struct Unit {
        let dimension: String
        let factor: Double   // to the base unit
        var offset: Double = 0
    }

    private static let units: [String: Unit] = {
        var u: [String: Unit] = [:]
        func add(_ names: [String], _ dim: String, _ factor: Double, offset: Double = 0) {
            for n in names { u[n] = Unit(dimension: dim, factor: factor, offset: offset) }
        }
        add(["mm"], "length", 0.001); add(["cm"], "length", 0.01); add(["m", "meter", "meters"], "length", 1)
        add(["km"], "length", 1000); add(["in", "inch", "inches"], "length", 0.0254)
        add(["ft", "foot", "feet"], "length", 0.3048); add(["yd"], "length", 0.9144)
        add(["mi", "mile", "miles"], "length", 1609.344)
        add(["mg"], "mass", 0.001); add(["g"], "mass", 1); add(["kg"], "mass", 1000)
        add(["oz"], "mass", 28.349523125); add(["lb", "lbs"], "mass", 453.59237)
        add(["ms"], "time", 0.001); add(["s", "sec", "secs"], "time", 1); add(["min", "mins"], "time", 60)
        add(["h", "hr", "hrs", "hour", "hours"], "time", 3600); add(["d", "day", "days"], "time", 86_400)
        add(["week", "weeks"], "time", 604_800)
        add(["b", "byte", "bytes"], "data", 1)
        add(["kb"], "data", 1e3); add(["mb"], "data", 1e6); add(["gb"], "data", 1e9); add(["tb"], "data", 1e12)
        add(["kib"], "data", 1024); add(["mib"], "data", 1_048_576)
        add(["gib"], "data", 1_073_741_824); add(["tib"], "data", 1_099_511_627_776)
        add(["c", "°c", "celsius"], "temperature", 1)
        add(["f", "°f", "fahrenheit"], "temperature", 5.0 / 9.0, offset: -32)
        add(["k", "kelvin"], "temperature", 1, offset: -273.15)
        return u
    }()

    /// "<expr> <unit> in|to|as <unit>"
    private static func convert(_ s: String) -> Result? {
        guard let sep = [" in ", " to ", " as "].compactMap({ s.range(of: $0, options: .backwards) })
            .max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let toName = s[sep.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        // The source unit is the trailing letters of the left side: "1.5gb", "10 km".
        let left = s[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
        let unitStart = left.lastIndex(where: { !($0.isLetter || $0 == "°") }).map { left.index(after: $0) } ?? left.startIndex
        let fromName = left[unitStart...].lowercased()
        let expr = left[..<unitStart]
        guard let from = units[fromName], let to = units[toName], from.dimension == to.dimension else { return nil }
        var p = Parser(String(expr))
        guard let v = p.parseAll() else { return nil }
        // Temperatures: (v + offset) * factor gives Celsius; invert for the target.
        let base = (v + from.offset) * from.factor
        let out = base / to.factor - to.offset
        guard out.isFinite else { return nil }
        return Result(value: out, unit: toName)
    }

    private static func looksLikeMath(_ s: String) -> Bool {
        guard s.contains(where: { $0.isNumber }) else { return false }
        if s.range(of: #"[+\-*/^×÷%]|\b(sqrt|sin|cos|tan|log|ln|abs|round|floor|ceil)\s*\("#,
                   options: .regularExpression) != nil {
            // "-5" alone is just a number; "2025-10-16" is a date, not maths.
            if Double(s) != nil { return false }
            if s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return false }
            return true
        }
        return false
    }

    // MARK: - Formatting

    static func format(_ v: Double, grouping: Bool) -> String {
        if v == v.rounded(), abs(v) < 1e15 {
            let i = Int64(v)
            return grouping ? grouped(String(abs(i)), negative: i < 0) : String(i)
        }
        var s = String(format: "%.10g", v)
        if s.contains("e") { return s }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        guard grouping else { return s }
        let parts = s.split(separator: ".", maxSplits: 1)
        let intPart = String(parts[0]).replacingOccurrences(of: "-", with: "")
        let frac = parts.count > 1 ? "." + parts[1] : ""
        return grouped(intPart, negative: s.hasPrefix("-")) + frac
    }

    private static func grouped(_ digits: String, negative: Bool) -> String {
        var out = ""
        for (i, c) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (negative ? "-" : "") + String(out.reversed())
    }

    // MARK: - Parser

    /// expr := term (('+'|'-') term)*
    /// term := power (('*'|'/'|'of') power)*
    /// power := unary ('^' power)?
    /// unary := '-' unary | postfix
    /// postfix := primary '%'?
    /// primary := number | constant | func '(' expr ')' | '(' expr ')'
    private struct Parser {
        let chars: [Character]
        var i = 0

        init(_ s: String) {
            chars = Array(s.replacingOccurrences(of: "**", with: "^")
                .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: "_", with: "").lowercased())
        }

        mutating func parseAll() -> Double? {
            guard let v = expr() else { return nil }
            skipSpaces()
            return i == chars.count ? v : nil
        }

        private mutating func skipSpaces() { while i < chars.count, chars[i] == " " { i += 1 } }

        private mutating func peek(_ c: Character) -> Bool {
            skipSpaces()
            guard i < chars.count, chars[i] == c else { return false }
            i += 1
            return true
        }

        private mutating func peekWord(_ w: String) -> Bool {
            skipSpaces()
            let word = Array(w)
            guard i + word.count <= chars.count, Array(chars[i..<i + word.count]) == word else { return false }
            let end = i + word.count
            if end < chars.count, chars[end].isLetter { return false }
            i = end
            return true
        }

        private mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while true {
                if peek("+") { guard let r = term() else { return nil }; v += r }
                else if peek("-") { guard let r = term() else { return nil }; v -= r }
                else { return v }
            }
        }

        private mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while true {
                if peek("*") || peekWord("of") { guard let r = power() else { return nil }; v *= r }
                else if peek("/") { guard let r = power(), r != 0 else { return nil }; v /= r }
                else { return v }
            }
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek("^") { guard let e = power() else { return nil }; return pow(base, e) }
            return base
        }

        private mutating func unary() -> Double? {
            if peek("-") { return unary().map { -$0 } }
            if peek("+") { return unary() }
            return postfix()
        }

        private mutating func postfix() -> Double? {
            guard let v = primary() else { return nil }
            if peek("%") { return v / 100 }
            return v
        }

        private mutating func primary() -> Double? {
            skipSpaces()
            guard i < chars.count else { return nil }
            if peek("(") {
                guard let v = expr(), peek(")") else { return nil }
                return v
            }
            if chars[i].isNumber || chars[i] == "." { return number() }
            if chars[i].isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber { name.append(chars[i]); i += 1 }
                switch name {
                case "pi", "π": return .pi
                case "e": return M_E
                default: break
                }
                guard peek("("), let arg = expr(), peek(")") else { return nil }
                switch name {
                case "sqrt": return arg >= 0 ? sqrt(arg) : nil
                case "sin": return sin(arg)
                case "cos": return cos(arg)
                case "tan": return tan(arg)
                case "log": return arg > 0 ? log10(arg) : nil
                case "ln": return arg > 0 ? log(arg) : nil
                case "abs": return abs(arg)
                case "round": return arg.rounded()
                case "floor": return floor(arg)
                case "ceil": return ceil(arg)
                default: return nil
                }
            }
            return nil
        }

        private mutating func number() -> Double? {
            if i + 1 < chars.count, chars[i] == "0", chars[i + 1] == "x" {
                var j = i + 2, hex = ""
                while j < chars.count, chars[j].isHexDigit { hex.append(chars[j]); j += 1 }
                guard let v = UInt64(hex, radix: 16) else { return nil }
                i = j
                return Double(v)
            }
            var s = ""
            while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "," {
                if chars[i] != "," { s.append(chars[i]) }
                i += 1
            }
            // Scientific notation: 1e6, 2.5e-3
            if i < chars.count, chars[i] == "e", i + 1 < chars.count,
               chars[i + 1].isNumber || ((chars[i + 1] == "-" || chars[i + 1] == "+") && i + 2 < chars.count && chars[i + 2].isNumber) {
                s.append("e"); i += 1
                if chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                while i < chars.count, chars[i].isNumber { s.append(chars[i]); i += 1 }
            }
            // Suffixes: 10k, 2.5m
            if i < chars.count, (chars[i] == "k" || chars[i] == "m"), !(i + 1 < chars.count && chars[i + 1].isLetter) {
                let mult: Double = chars[i] == "k" ? 1e3 : 1e6
                i += 1
                return Double(s).map { $0 * mult }
            }
            return Double(s)
        }
    }
}
