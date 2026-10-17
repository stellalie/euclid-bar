import Foundation

/// Compact "how long ago" for list rows: "just now", "5m ago", "2h ago", "3d ago", "6w ago", then a date.
public enum RelativeAge {
    public static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "just now"
        case ..<3_600: return "\(s / 60)m ago"
        case ..<86_400: return "\(s / 3_600)h ago"
        case ..<(7 * 86_400): return "\(s / 86_400)d ago"
        case ..<(8 * 7 * 86_400): return "\(s / (7 * 86_400))w ago"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            return date.formatted(sameYear ? style : style.year())
        }
    }
}
