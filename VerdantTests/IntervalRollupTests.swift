import Foundation
import HealthKit
import Testing
@testable import Verdant

/// The interval path's per-day merge — how sleep and mindful minutes become daily rollups, and which
/// sources those days are attributed to.
///
/// This had no coverage at all. It is reachable only through `HealthStore`, and the ingest tests
/// enter one level above it via `HealthReading`, so both its arithmetic and (newly) its provenance
/// ran entirely unexercised. `mergedDailyRollups` is internal for this reason.
struct IntervalRollupTests {
    private let calendar = Calendar.civil

    private var day0: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
    }

    private var day1: Date {
        day0.addingTimeInterval(86400)
    }

    private func at(_ day: Date, _ hour: Double) -> Date {
        day.addingTimeInterval(hour * 3600)
    }

    private var spec: HealthStore.IntervalSpec {
        HealthStore.IntervalSpec(
            metric: .sleepDurationHours, identifier: .sleepAnalysis, divisor: 3600, include: { _ in true }
        )
    }

    private func rollups(_ intervals: [SleepAggregation.Interval]) -> [DayRollup] {
        HealthStore.mergedDailyRollups(
            spec, intervals: intervals, from: day0, to: day1.addingTimeInterval(86400),
            calendar: calendar
        )
    }

    /// The arithmetic, first — the provenance assertions below are worthless if the value is wrong.
    @Test func `overlapping stages from one source are merged, not summed`() throws {
        let watch = [
            SleepAggregation.Interval(start: at(day0, 1), end: at(day0, 4), source: "Watch"),
            SleepAggregation.Interval(start: at(day0, 3), end: at(day0, 5), source: "Watch")
        ]
        let row = try #require(rollups(watch).first)
        #expect(row.values.mean == 4, "summed to \(row.values.mean) instead of merging the overlap")
        #expect(row.values.sources == ["Watch"])
    }

    /// Two devices recording the same night is one merged duration and two sources. The merge
    /// deliberately collapses them, so membership cannot be read off the merged runs.
    @Test func `a day recorded by two devices lists both`() throws {
        let both = [
            SleepAggregation.Interval(start: at(day0, 1), end: at(day0, 5), source: "Watch"),
            SleepAggregation.Interval(start: at(day0, 2), end: at(day0, 6), source: "Phone")
        ]
        let row = try #require(rollups(both).first)
        #expect(row.values.mean == 5, "the two sources were double-counted")
        #expect(row.values.sources == ["Phone", "Watch"], "got \(row.values.sources)")
    }

    /// A night crossing midnight belongs to both days, and so does its source — it really did record
    /// on both.
    @Test func `a session crossing midnight attributes its source to both days`() {
        let overnight = [
            SleepAggregation.Interval(start: at(day0, 23), end: at(day1, 6), source: "Watch")
        ]
        let rows = rollups(overnight)
        #expect(rows.count == 2, "expected both days, got \(rows.count)")
        #expect(rows.allSatisfy { $0.values.sources == ["Watch"] })
        #expect(rows[0].values.mean == 1, "the pre-midnight hour was mis-attributed")
        #expect(rows[1].values.mean == 6)
    }

    /// The case that prompted the fix. `DayMath.daysTouched` is inclusive of the end day, so a
    /// session ending at exactly midnight is bucketed onto the following day while contributing
    /// nothing to it. Reading provenance from what was BUCKETED would put that source in one day's
    /// signature and no other — a one-day flicker manufactured at a midnight boundary, which
    /// `ProvenanceScan` cannot tell from a real brief change of device.
    @Test func `a source that contributes no time to a day is not credited with it`() throws {
        let intervals = [
            // Ends exactly at midnight: touches day1, contributes zero seconds to it.
            SleepAggregation.Interval(start: at(day0, 22), end: day1, source: "Old Watch"),
            SleepAggregation.Interval(start: at(day1, 1), end: at(day1, 7), source: "New Watch")
        ]
        let rows = rollups(intervals)
        let second = try #require(rows.first { $0.dayStart == day1 })
        #expect(
            second.values.sources == ["New Watch"],
            "a source that recorded no time on this day joined its signature: \(second.values.sources)"
        )
        // And it is still credited on the day it DID record.
        let first = try #require(rows.first { $0.dayStart == day0 })
        #expect(first.values.sources == ["Old Watch"])
    }

    /// A day whose every interval contributes nothing produces no rollup at all, rather than an
    /// empty-sourced zero that would read as a real observation of no sleep.
    @Test func `a day with no contributed time produces no row`() {
        let touching = [
            SleepAggregation.Interval(start: at(day0, 22), end: day1, source: "Watch")
        ]
        #expect(!rollups(touching).contains { $0.dayStart == day1 })
    }
}
