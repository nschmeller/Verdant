import Foundation
import Testing
@testable import Verdant

// A local start-of-day, so hour offsets cross midnight predictably for day-math tests.
private let base = Calendar.civil.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
private func hours(_ count: Double) -> Date {
    base.addingTimeInterval(count * 3600)
}

private func interval(_ start: Double, _ end: Double) -> SleepAggregation.Interval {
    SleepAggregation.Interval(start: hours(start), end: hours(end))
}

struct SleepAggregationTests {
    private let dayStart = base
    private var dayEnd: Date {
        base.addingTimeInterval(86400)
    }

    /// Merged duration expressed in hours — the production code divides `mergedSeconds` by its own
    /// per-unit divisor at the call site, so the hours conversion lives here in the test.
    private func asleepHours(_ intervals: [SleepAggregation.Interval]) -> (hours: Double, mergedCount: Int)? {
        guard let result = SleepAggregation.mergedSeconds(
            intervals: intervals, dayStart: dayStart, dayEnd: dayEnd
        ) else { return nil }
        return (result.seconds / 3600, result.mergedCount)
    }

    /// **Sleep is attributed to the CIVIL DAY it occurs in, not to the night it belongs to.** A
    /// night from 23:00 to 07:00 becomes 1h on the first day and 7h on the second; the same eight
    /// hours shifted an hour later would land entirely on one day. Both ingest paths clamp to the
    /// day this way (`HealthStore.categoryDurationValues` and `HealthStore+Range
    /// .mergedDailyRollups`), so it is consistent — but it is a real measurement choice, currently
    /// undocumented, and it sits in tension with the investigator lens that asks about "sleep and
    /// its downstream effects on NEXT-DAY recovery": that lens presumes a night belongs to one day.
    ///
    /// Pinned so the semantics are visible and any change to them is deliberate rather than
    /// incidental. Not asserted to be correct — see the note in ARCHITECTURE.
    @Test func `a night spanning midnight is SPLIT across both civil days`() throws {
        // 23:00 → 07:00, expressed against this day and the previous one.
        let previousNight = SleepAggregation.Interval(start: hours(-1), end: hours(7))
        let thisDay = try #require(asleepHours([previousNight]))
        #expect(abs(thisDay.hours - 7) < 1e-6) // only the post-midnight portion lands here

        let priorDayStart = base.addingTimeInterval(-86400)
        let priorDay = try #require(SleepAggregation.mergedSeconds(
            intervals: [previousNight], dayStart: priorDayStart, dayEnd: base
        ))
        #expect(abs(priorDay.seconds / 3600 - 1) < 1e-6) // the pre-midnight hour lands there

        // A later night of the SAME length lands wholly on one day — so identical sleep produces
        // different daily series depending only on bedtime relative to midnight.
        let lateNight = SleepAggregation.Interval(start: hours(1), end: hours(9))
        let whollyToday = try #require(asleepHours([lateNight]))
        #expect(abs(whollyToday.hours - 8) < 1e-6)
    }

    @Test func `sums disjoint intervals`() throws {
        let result = try #require(asleepHours([interval(1, 5), interval(6, 8)]))
        #expect(abs(result.hours - 6) < 1e-6)
        #expect(result.mergedCount == 2)
    }

    @Test func `merges overlaps instead of double counting`() throws {
        // [1,5] and [3,7] overlap; naive sum = 8h, correct merged = 6h.
        let result = try #require(asleepHours([interval(1, 5), interval(3, 7)]))
        #expect(abs(result.hours - 6) < 1e-6)
        #expect(result.mergedCount == 1)
    }

    /// The case the merge comment names: "multiple sources (Watch + phone) aren't double-counted".
    /// Two devices recording the SAME night produce identical or near-identical intervals, and a
    /// naive sum would report sixteen hours of sleep.
    @Test func `the same night from two sources counts once`() throws {
        let identical = try #require(asleepHours([interval(23 - 23, 8), interval(0, 8)]))
        #expect(abs(identical.hours - 8) < 1e-6, "double-counted a second source")
        #expect(identical.mergedCount == 1)
    }

    /// The nastier shape: one source's session CONTAINS another's fragment. Merging must keep the
    /// longer run — taking the later interval's end unconditionally would shrink an eight-hour night
    /// to the two-hour fragment inside it, on the app's most prized metric.
    @Test func `a contained fragment does not shrink the night`() throws {
        let containing = try #require(asleepHours([interval(0, 8), interval(3, 5)]))
        #expect(abs(containing.hours - 8) < 1e-6, "a contained fragment truncated the night")
        #expect(containing.mergedCount == 1)

        // And in the other arrival order, since the merge sorts by start.
        let reversed = try #require(asleepHours([interval(3, 5), interval(0, 8)]))
        #expect(abs(reversed.hours - 8) < 1e-6)
    }

    /// Adjacent stages from one source (core → deep → REM) touch rather than overlap. They are one
    /// night, not three, or `mergedCount` would misreport how fragmented the sleep was.
    @Test func `touching stages merge into a single run`() throws {
        let staged = try #require(asleepHours([interval(0, 3), interval(3, 5), interval(5, 8)]))
        #expect(abs(staged.hours - 8) < 1e-6)
        #expect(staged.mergedCount == 1, "adjacent stages reported as \(staged.mergedCount) runs")
    }

    @Test func `clamps to the day`() throws {
        // Starts before the day and ends after it; only the in-day portion counts.
        let result = try #require(asleepHours([interval(-2, 3), interval(22, 26)]))
        #expect(abs(result.hours - 5) < 1e-6) // 3h + 2h
        #expect(result.mergedCount == 2)
    }

    @Test func `returns nil when nothing in day`() {
        #expect(asleepHours([]) == nil)
        #expect(asleepHours([interval(30, 34)]) == nil)
    }
}

/// Where a night actually LANDS, worked through in three time zones.
///
/// `SleepAggregation`'s doc said a night spanning midnight is "SPLIT: 23:00→07:00 gives 1h to the
/// first day and 7h to the second". That is the near-UTC case only. `Calendar.civil` is pinned to
/// UTC, so the cut happens at UTC midnight — some local hour that depends on the user's offset — and
/// for most of the world a normal night does not straddle it at all. The identical error lived in
/// the investigator's sleep lens until it was corrected there and not here.
///
/// It matters for the open product decision: for a US user the app ALREADY attributes a night to the
/// day it ends, which is the conventional fix being proposed. These pin the arithmetic so the
/// decision is made against behaviour rather than against a sentence.
struct SleepDayAttributionTests {
    /// 23:00 → 07:00 in a given UTC offset, as absolute instants.
    private func night(offsetHours: Int) -> SleepAggregation.Interval {
        let day = Date(timeIntervalSince1970: 1_700_000_000) // a fixed UTC instant
        let utcMidnight = Calendar.civil.startOfDay(for: day)
        // Local 23:00 on that civil day == UTC 23:00 - offset.
        let start = utcMidnight.addingTimeInterval(TimeInterval((23 - offsetHours) * 3600))
        return SleepAggregation.Interval(start: start, end: start.addingTimeInterval(8 * 3600))
    }

    private func hours(_ interval: SleepAggregation.Interval, onDayOf instant: Date) -> Double {
        let dayStart = Calendar.civil.startOfDay(for: instant)
        return interval.seconds(within: dayStart) / 3600
    }

    /// Pacific: UTC midnight falls at ~16:00 local, so the whole night is after it — the wake day.
    @Test func `a US-Pacific night lands wholly on one civil day`() {
        let sleep = night(offsetHours: -8)
        let onsetDay = hours(sleep, onDayOf: sleep.start)
        #expect(onsetDay == 8, "expected the whole night on one day, got \(onsetDay)h")
    }

    /// Japan: UTC midnight falls at ~09:00 local, so the whole night precedes it — the onset day.
    @Test func `a Japan night also lands wholly on one civil day`() {
        let sleep = night(offsetHours: 9)
        let onsetDay = hours(sleep, onDayOf: sleep.start)
        #expect(onsetDay == 8, "expected the whole night on one day, got \(onsetDay)h")
    }

    /// UK: the only case the old comment described — 1h before the boundary, 7h after.
    @Test func `a UK night is the one that genuinely splits`() {
        let sleep = night(offsetHours: 0)
        #expect(hours(sleep, onDayOf: sleep.start) == 1)
        #expect(hours(sleep, onDayOf: sleep.end) == 7)
    }

    /// The two whole-night cases land on DIFFERENT days relative to the sleeper, which is the part
    /// that makes "attribute to the day it ends" a change rather than a no-op — and the part a
    /// single-timezone fixture cannot show.
    @Test func `the two whole-night cases fall on opposite sides of the sleeper's night`() {
        let pacific = night(offsetHours: -8)
        let japan = night(offsetHours: 9)
        // Pacific: the civil day holding the night is the one its END is in (the wake day).
        #expect(Calendar.civil.startOfDay(for: pacific.start)
            == Calendar.civil.startOfDay(for: pacific.end))
        #expect(hours(pacific, onDayOf: pacific.end) == 8)
        // Japan: likewise one day, but reached from the onset side — the night ends before the cut.
        #expect(hours(japan, onDayOf: japan.start) == 8)
        // And they are not the same civil day, given identical local clock times.
        #expect(Calendar.civil.startOfDay(for: pacific.start)
            != Calendar.civil.startOfDay(for: japan.start))
    }
}

/// What "weekend" means once the day boundary is UTC — the second half of a documented question.
///
/// `CivilCalendar` records that weekend membership is Saturday/Sunday for every user because the
/// calendar sets no locale, and calls the fix "cheap, re-keys nothing". That is true of the LOCALE
/// half. It is not the whole problem: `isDateInWeekend` is asked about a UTC-midnight rollup key, so
/// for anyone not near UTC the label is applied to a day that is offset from the one they lived.
///
/// These pin the shift rather than describe it, because it decides how much the open question is
/// actually worth: switching to `Locale.current` fixes Friday/Saturday regions and leaves every
/// non-UTC user's weekend buckets straddling two of their days.
struct WeekendBoundaryTests {
    private let calendar = Calendar.civil

    /// A Friday evening in California falls inside the civil day the app calls Saturday.
    @Test func `a Pacific Friday evening is bucketed into the weekend`() throws {
        // 2026-01-16 was a Friday. 18:00 Pacific (UTC-8) is 02:00 UTC on the 17th, a Saturday.
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 17
        components.hour = 2
        let fridayEveningLocal = try #require(calendar.date(from: components))
        #expect(
            calendar.isDateInWeekend(fridayEveningLocal),
            "the app does not call this instant a weekend, so the fixture is wrong"
        )
        // And the same instant is a Friday where the user is standing.
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        #expect(pacific.component(.weekday, from: fridayEveningLocal) == 6, "not a Friday locally")
    }

    /// And the mirror: a Sunday evening in California is bucketed into Monday, so it leaves the
    /// weekend side of the comparison altogether.
    @Test func `a Pacific Sunday evening is bucketed out of the weekend`() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 19 // Monday, UTC
        components.hour = 2
        let sundayEveningLocal = try #require(calendar.date(from: components))
        #expect(!calendar.isDateInWeekend(sundayEveningLocal))
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        #expect(pacific.component(.weekday, from: sundayEveningLocal) == 1, "not a Sunday locally")
    }

    /// Near UTC the two agree, which is why this is invisible to anyone developing in London.
    @Test func `near UTC the label matches the day the user lived`() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 17 // Saturday
        components.hour = 12
        let saturdayMidday = try #require(calendar.date(from: components))
        #expect(calendar.isDateInWeekend(saturdayMidday))
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(london.component(.weekday, from: saturdayMidday) == 7)
    }
}

struct DayMathTests {
    @Test func `single day for intraday interval`() {
        let days = DayMath.daysTouched(start: hours(1), end: hours(5))
        #expect(days.count == 1)
    }

    @Test func `two days when crossing midnight`() {
        let days = DayMath.daysTouched(start: hours(22), end: hours(30))
        #expect(days.count == 2)
    }

    @Test func `spans every day touched`() {
        let days = DayMath.daysTouched(start: hours(1), end: hours(50))
        #expect(days.count == 3)
    }
}

struct IngestWindowTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test func `incremental ingest only revisits the recent window`() {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let start = Ingestor.recomputeWindowStart(today: today, calendar: calendar)
        let span = calendar.dateComponents([.day], from: start, to: today).day
        #expect(span == Ingestor.activeWindowDays - 1)
    }

    // First ingest has no window pin anymore BY DESIGN: it backfills from the metric's earliest
    // HealthKit sample (all-time), so the only pure logic left is the deepening span below.

    @Test func `deepen span runs from the earliest sample to the earliest rollup`() throws {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let dayAfterToday = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        let sample = try #require(calendar.date(byAdding: .day, value: -3000, to: today)?
            .addingTimeInterval(3600))
        let rollup = try #require(calendar.date(byAdding: .day, value: -1825, to: today))
        let span = try #require(Ingestor.deepenSpan(
            earliestSample: sample, earliestRollup: rollup, dayAfterToday: dayAfterToday,
            calendar: calendar
        ))
        // Snapped to the sample's civil day start, ending exactly where existing rollups begin.
        #expect(span.from == calendar.startOfDay(for: sample))
        #expect(span.to == rollup)
    }

    @Test func `deepen span covers the whole history when no rollups exist`() throws {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let dayAfterToday = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        let sample = try #require(calendar.date(byAdding: .day, value: -400, to: today))
        let span = try #require(Ingestor.deepenSpan(
            earliestSample: sample, earliestRollup: nil, dayAfterToday: dayAfterToday,
            calendar: calendar
        ))
        #expect(span.from == sample)
        #expect(span.to == dayAfterToday)
    }

    @Test func `deepen span is nil when there is nothing older to recover`() throws {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let dayAfterToday = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        // No samples at all.
        #expect(Ingestor.deepenSpan(
            earliestSample: nil, earliestRollup: today, dayAfterToday: dayAfterToday,
            calendar: calendar
        ) == nil)
        // Rollups already reach the earliest sample's day.
        let day = try #require(calendar.date(byAdding: .day, value: -100, to: today))
        #expect(Ingestor.deepenSpan(
            earliestSample: day.addingTimeInterval(600), earliestRollup: day,
            dayAfterToday: dayAfterToday, calendar: calendar
        ) == nil)
    }
}

struct MetricFormattingTests {
    @Test func `formats discrete units with label`() {
        #expect(MetricFormatting.formatted(62, .restingHeartRate) == "62 bpm")
        #expect(MetricFormatting.formatted(450, .activeEnergyBurned) == "450 kcal")
    }

    @Test func `formats fractional units to one decimal`() {
        #expect(MetricFormatting.number(7.3, .sleepDurationHours) == "7.3")
    }

    @Test func `formats percent as a whole number with no space`() {
        // oxygenSaturation stores a 0–1 fraction; display ×100.
        #expect(MetricFormatting.formatted(0.97, .oxygenSaturation) == "97%")
    }

    @Test func `formats distance from meters to kilometers`() {
        #expect(MetricFormatting.formatted(5000, .distanceWalkingRunning) == "5.0 km")
    }

    @Test func `signed percent uses explicit sign`() {
        #expect(MetricFormatting.signedPercent(18.2) == "+18%")
        #expect(MetricFormatting.signedPercent(-11.6) == "−12%")
        #expect(MetricFormatting.signedPercent(0) == "±0%")
    }
}

struct RollupKeyTests {
    @Test func `key is stable and unique`() {
        let day = base
        let key = MetricRollup.makeKey(metric: .stepCount, dayStart: day)
        #expect(key == MetricRollup.makeKey(metric: .stepCount, dayStart: day))
        #expect(key != MetricRollup.makeKey(metric: .restingHeartRate, dayStart: day))
    }

    @Test func `the day grid is a fixed UTC civil day so a physical day has one key`() {
        // The regression this guards: keying off a LOCAL-midnight instant made the same physical day
        // re-key (and duplicate-row → double-count) whenever the user crossed a time zone. The civil
        // calendar is fixed to UTC, so every instant within one civil day collapses to one start-of-day
        // and therefore one rollup key, regardless of the device's current zone.
        #expect(Calendar.civil.timeZone.secondsFromGMT() == 0)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let civilDay = Calendar.civil.startOfDay(for: instant)
        let laterSameDay = civilDay.addingTimeInterval(20 * 3600) // 20h later, still the same civil day
        #expect(Calendar.civil.startOfDay(for: laterSameDay) == civilDay)
        #expect(
            MetricRollup.makeKey(metric: .stepCount, dayStart: Calendar.civil.startOfDay(for: instant))
                == MetricRollup.makeKey(
                    metric: .stepCount,
                    dayStart: Calendar.civil.startOfDay(for: laterSameDay)
                )
        )
    }

    @Test func `day value follows aggregation`() {
        let summed = MetricRollup(
            key: "k", metric: MetricKey.stepCount.rawValue, dayStart: base,
            mean: 1, count: 1, sum: 9000
        )
        #expect(summed.dayValue(for: .stepCount) == 9000) // cumulative → sum
        let averaged = MetricRollup(
            key: "k2", metric: MetricKey.restingHeartRate.rawValue, dayStart: base,
            mean: 58, count: 10, sum: 580
        )
        #expect(averaged.dayValue(for: .restingHeartRate) == 58) // discrete → mean
    }
}

/// The per-metric catalog decides how each day's samples collapse to one value. A `.sum`/`.average`
/// mix-up is silent and catastrophic: it doesn't crash, it just multiplies every value and every
/// finding for that metric by the day's sample count (or divides a daily total down to one reading).
struct MetricCatalogTests {
    @Test func `rate and level metrics are averaged, never summed`() {
        // Intensive units — a rate or an instantaneous level. Summing a day's readings is physically
        // meaningless (resting heart rate or body weight "added up" across the day is nonsense), so
        // these MUST average. Extensive units (counts, distance, energy, durations, intake) are NOT
        // asserted here because the right choice varies — e.g. BMI is a `.count` unit but is averaged.
        let intensive: Set<UnitKind> = [
            .perMinute, .milliseconds, .vo2Max, .percent, .celsius,
            .kilograms, .centimeters, .metersPerSecond, .decibels
        ]
        for metric in MetricKey.allCases where intensive.contains(metric.unitKind) {
            #expect(metric.aggregation == .average, "\(metric) is an intensive unit but is summed")
        }
    }

    @Test func `every metric has a display name`() {
        // The display name titles every finding card and names the metric in Q&A answers; an empty one
        // is a blank "bit of text" the bar forbids — a cheap guard that a new case was fully configured.
        for metric in MetricKey.allCases {
            #expect(!metric.displayName.isEmpty, "\(metric) has no display name")
        }
    }

    @Test func `a watch vital is always a sensed, averaged metric — never a cumulative count`() {
        // The device-swap filter suppresses days where several watch vitals step at once (a sensor
        // recalibration). That premise only holds for instantaneously-sensed values, which average. A
        // cumulative metric (steps, distance, energy) doesn't "recalibrate" — flagging one as a vital
        // would make the filter wrongly discard real activity findings as device swaps.
        for metric in MetricKey.allCases where metric.isWatchVital {
            #expect(metric.aggregation == .average, "\(metric) is a watch vital but is a summed metric")
        }
    }
}

/// The feed is meant to hold a *handful* of standout findings — the product ethos pins this at 3–12.
/// The curation tests exercise the trimming with explicit budgets; this pins the shipped policy
/// constant itself, so the budget can't silently drift into "a wall of findings" (dilution) or below
/// what can hold a few independent insights.
struct FindingsBudgetTests {
    @Test func `the active findings budget stays within the 3 to 12 handful`() {
        #expect(EnhancementPolicy.maxActiveFindings >= 3)
        #expect(EnhancementPolicy.maxActiveFindings <= 12)
    }
}
