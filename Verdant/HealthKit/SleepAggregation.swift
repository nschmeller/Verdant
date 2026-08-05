import Foundation

/// Pure interval-duration math (used for any category type derived by summing durations: sleep,
/// mindful sessions). Extracted from HealthKit access so it can be unit-tested directly.
///
/// **Day attribution — a real measurement choice, and it is NOT "split".** Intervals are clamped to
/// the civil day, and `Calendar.civil` is pinned to **UTC**, so the boundary a night is cut on is
/// UTC midnight — which is some local hour that depends entirely on where the user is. Working a
/// 23:00→07:00 night through:
///
///     US-Pacific (UTC-8)   boundary ~16:00 local   -> 07:00-15:00 UTC, wholly on the WAKE day
///     Japan      (UTC+9)   boundary ~09:00 local   -> 14:00-22:00 UTC, wholly on the ONSET day
///     UK         (UTC+0)   boundary  00:00 local   -> genuinely split, 1h then 7h
///
/// This comment used to state the last row flatly, as though splitting were the behaviour. It is the
/// near-UTC case only, and the same error lived in the investigator's own sleep lens until
/// 2026-08-02; it was corrected there and not here. The distinction is not academic: for a US user
/// the app ALREADY attributes a night to the day it ends, which is the conventional fix — so
/// "attribute to the wake day" would change nothing for them, change Japan's behaviour completely,
/// and only fix the narrow band where nights really do straddle the boundary.
///
/// What is true everywhere: the attribution depends on the user's offset from UTC rather than on
/// their sleep, so a traveller's series shifts under them, and the app cannot tell any of these
/// cases apart from the rollups alone.
///
/// It sits in tension with how the app reasons about sleep: one investigator lens asks about "sleep
/// and its downstream effects on NEXT-DAY recovery", which presumes a night belongs to a single day
/// — true in Pacific, true in Japan, and wrong about WHICH day in one of them. Lead-lag correlations
/// involving sleep are the app's most prized finding type. The conventional alternatives are to
/// attribute a session to the day it ENDS or to bucket 6pm–6pm local. Either re-keys every stored
/// sleep rollup, so it is a product decision rather than a fix to make in passing — left as-is
/// deliberately, pinned by `SleepAggregationTests`, and recorded in ARCHITECTURE as open.
nonisolated enum SleepAggregation {
    nonisolated struct Interval: Equatable {
        let start: Date
        let end: Date
        /// Which app or device recorded this stretch. Carried so the range path can report a day's
        /// provenance; the merge itself ignores it. Defaults to unknown for the arithmetic tests,
        /// which are about overlap, not origin.
        var source: String = ""

        /// Seconds this interval contributes to the civil day beginning at `dayStart`, clamped to
        /// that day. Zero when it merely abuts the boundary — which is the case that separates
        /// "recorded time here" from "was bucketed here".
        func seconds(within dayStart: Date) -> TimeInterval {
            let dayEnd = dayStart.addingTimeInterval(86400)
            return max(0, min(end, dayEnd).timeIntervalSince(max(start, dayStart)))
        }
    }

    /// Total non-overlapping seconds for a day: clamp each interval to `[dayStart, dayEnd]`, then
    /// MERGE overlaps so overlapping stages or multiple sources (Watch + phone) aren't
    /// double-counted. Returns `nil` if nothing falls within the day; `mergedCount` is the number of
    /// disjoint runs after merging.
    static func mergedSeconds(
        intervals: [Interval],
        dayStart: Date,
        dayEnd: Date
    ) -> (seconds: Double, mergedCount: Int)? {
        var clamped: [(start: Date, end: Date)] = []
        for interval in intervals {
            let start = max(interval.start, dayStart)
            let end = min(interval.end, dayEnd)
            if end > start { clamped.append((start, end)) }
        }
        guard !clamped.isEmpty else { return nil }

        clamped.sort { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for interval in clamped {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        let seconds = merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return (seconds, merged.count)
    }
}
