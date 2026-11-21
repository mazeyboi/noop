import Foundation

/// Text <-> number for the food log's number fields. Parsed on every keystroke (a decimal pad has no
/// Return key, so a value-bound field would never commit before Save is tapped).
public enum NumberInput {
    /// "250", "12,5", " 7.25 " -> number; empty, negative or not a number -> nil.
    public static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// The text a field shows for a value: "" for 0, no trailing ".0", at most one decimal.
    public static func text(_ v: Double) -> String {
        guard v != 0, v.isFinite else { return "" }
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
}

/// Which day the food log shows. It follows "today" (also across midnight, in an app that stays alive
/// for days) until another day is picked.
public struct DaySelection: Equatable, Sendable {
    public private(set) var day: Date
    public private(set) var followsToday: Bool

    public init(now: Date, calendar: Calendar = .current) {
        day = calendar.startOfDay(for: now)
        followsToday = true
    }

    /// Call when the app or screen becomes active.
    public mutating func refresh(now: Date, calendar: Calendar = .current) {
        if followsToday { day = calendar.startOfDay(for: now) }
    }

    public mutating func shift(by days: Int, now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let target = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: day)) ?? day
        day = min(target, today)
        followsToday = calendar.isDate(day, inSameDayAs: today)
    }

    /// When an entry logged now belongs: now on today, noon on another day.
    public func logTime(now: Date, calendar: Calendar = .current) -> Date {
        if calendar.isDate(day, inSameDayAs: now) { return now }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }
}
