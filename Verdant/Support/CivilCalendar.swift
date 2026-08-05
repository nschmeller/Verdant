import Foundation

extension Calendar {
    /// The fixed calendar used for EVERY day-boundary computation in the data path — day attribution
    /// at ingest, the `MetricRollup` key, read-side day bucketing, the comparison windows, and all
    /// detector span/lag/first-difference arithmetic.
    ///
    /// It is Gregorian in **UTC**, so a given physical day maps to exactly ONE rollup identity no
    /// matter which time zone the device is in. `Calendar.current` does not: its `startOfDay` is local
    /// midnight, whose absolute instant shifts when the user travels — re-keying the same physical day
    /// to a second `MetricRollup` row, which the stats then double-count (a wrong number behind every
    /// finding). Verdant's findings are trends over days, so a consistent UTC boundary is correct; the
    /// only thing that must stay on `Calendar.current` is the wall-clock "within the last N days"
    /// freshness cutoffs (novelty/tombstone), which compare timestamps and never attribute a civil day.
    /// **Weekend membership is Saturday/Sunday for every user.** This calendar sets no locale, so
    /// `isDateInWeekend` uses the Gregorian default — verified, not assumed: the same calendar with
    /// `ar_SA` returns Friday/Saturday instead. That makes the `weekdayVsWeekend` comparison and
    /// `DayFilter.weekdays`/`.weekends` deterministic across devices, which is what the rest of this
    /// type is for, but it is simply WRONG for a user in a Friday/Saturday-weekend region: the app
    /// would call their working week "the weekend".
    ///
    /// **And that is only half of it.** `isDateInWeekend` is asked about a UTC-midnight rollup key,
    /// so for anyone away from UTC the label lands on a day offset from the one they lived. Pinned by
    /// `WeekendBoundaryTests`: for a US-Pacific user, Friday 18:00 local sits in the civil day the app
    /// calls Saturday, and Sunday 18:00 local sits in the one it calls Monday. A third of every
    /// "weekend" day is Friday evening, and Sunday evening is not in the weekend at all — on exactly
    /// the metrics (steps, active energy) where a weekday/weekend split is real, and in exactly the
    /// direction that flatters it.
    ///
    /// This matters for costing the decision, not just for describing it: switching to
    /// `Locale.current` fixes the Friday/Saturday regions and does NOTHING about the offset, because
    /// the offset comes from the day BOUNDARY rather than from which days are named. A weekend that
    /// means what the user means needs local-day bucketing, which is the expensive change recorded
    /// above — the same one sleep attribution needs, and for the same underlying reason.
    ///
    /// Left as-is deliberately — what "weekend" means is a product decision, and `Locale.current`
    /// also makes the split move when the user travels or changes region. Recorded as an open
    /// question in ARCHITECTURE; the note there that this one is "cheap" was true only of the locale
    /// half.
    nonisolated static let civil: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}

extension Calendar {
    /// Where the fixed UTC day boundary falls on the USER'S OWN wall clock, as a sentence an agent
    /// can act on.
    ///
    /// The sleep caveat handed to the investigator used to say only that attribution "depends on
    /// your time zone", which is true and useless: the fleet cannot weigh a one-day lead-lag result
    /// against an unknown. The offset is a fact the device knows, and turning it into a concrete
    /// boundary time tells the agent which of the three cases it is actually in — and, for most
    /// users, that a night lands WHOLLY on one day, so a lag-1 sleep link needs no discount at all.
    ///
    /// Facts to agents, decisions by agents: this states where the boundary is and lets the
    /// investigator judge what that means for its finding.
    nonisolated static func civilDayBoundary(in timeZone: TimeZone = .current) -> String {
        let offset = timeZone.secondsFromGMT()
        let secondsIntoLocalDay = ((offset % 86400) + 86400) % 86400
        let hour = secondsIntoLocalDay / 3600
        let minute = (secondsIntoLocalDay % 3600) / 60
        let clock = String(format: "%02d:%02d", hour, minute)
        if secondsIntoLocalDay == 0 {
            return "the day boundary is local midnight, so a night that crosses it is split in two"
        }
        // Before noon: the boundary sits inside the morning, so a night completes before it and is
        // recorded against the day the sleeper went to bed. After noon: the boundary is in the
        // afternoon/evening, the night begins after it, and the whole night lands on the wake day.
        let landing = hour < 12
            ? "a full night therefore lands wholly on the day the user FELL ASLEEP"
            : "a full night therefore lands wholly on the day the user WOKE"
        return "the day boundary falls at \(clock) local time, and \(landing)"
    }
}

extension Calendar {
    /// A day key rendered for an AGENT: ISO-style `2026-07-17`, always in the civil (UTC) calendar
    /// and never in a locale.
    ///
    /// `Date.formatted(date:time:)` was used here, and it is wrong twice over for this job. It
    /// renders in `TimeZone.current`, so a day keyed to UTC midnight displays as the PREVIOUS date
    /// for every user west of UTC — a strange day stored as 2026-07-17 was reported to the agent, and
    /// then to the user, as "Jul 16, 2026" anywhere in the Americas. And it renders in the device
    /// locale, so the same day reads "17.07.2026" in Germany, whose digits `NumericFidelity` then
    /// scrapes into the pool of "verified" numbers.
    ///
    /// ISO order is deliberate: unambiguous in every locale, and it sorts.
    nonisolated static func civilDayLabel(_ day: Date) -> String {
        let parts = civil.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
    }
}
