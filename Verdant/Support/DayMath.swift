import Foundation

/// Pure calendar-day helpers, extracted so day-bucketing logic is unit-testable.
nonisolated enum DayMath {
    /// Every calendar day (as start-of-day) the interval `[start, end]` touches, inclusive of both
    /// ends. Used so a sample crossing midnight (e.g. sleep) marks every affected day for
    /// recomputation, not just its start day.
    static func daysTouched(start: Date, end: Date, calendar: Calendar = .civil) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: max(end, start))
        days.append(day)
        while day < lastDay, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            days.append(next)
            day = next
        }
        return days
    }
}
