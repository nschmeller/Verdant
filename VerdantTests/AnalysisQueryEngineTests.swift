import Foundation
import Testing
@testable import Verdant

/// The agent-defined query engine: pure, deterministic views the agent designs itself (any window,
/// day-filter, statistic, or custom-window correlation). These pin the arithmetic so an agent can
/// *define* a view but can only ever *ask for* the number, never invent it.
struct AnalysisQueryEngineTests {
    private let calendar = Calendar.civil

    private func day(_ k: Int, from now: Date) -> Date {
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .day, value: -k, to: anchor)!
    }

    private func spec(
        _ metric: MetricKey,
        _ statistic: AnalysisStatistic,
        from: Int,
        to: Int,
        secondary: MetricKey? = nil,
        filter: DayFilter = .all,
        lag: Int = 0
    ) -> AnalysisSpec {
        AnalysisSpec(
            metric: metric, secondaryMetric: secondary ?? metric, statistic: statistic,
            fromDaysAgo: from, toDaysAgo: to, dayFilter: filter, lag: lag
        )
    }

    @Test func `mean over a custom window`() {
        let now = Date()
        var values: [Date: Double] = [:]
        for k in 0..<30 {
            values[day(k, from: now)] = 100
        }
        let series = [DailySeries(metric: .stepCount, values: values)]
        let out = AnalysisQueryEngine.evaluate(
            spec(.stepCount, .mean, from: 30, to: 0),
            series: series,
            now: now
        )
        #expect(out.available)
        #expect(abs(out.value - 100) < 1e-9)
        #expect(out.sampleCount == 30)
    }

    @Test func `a day filter narrows the sample to a subset`() {
        let now = Date()
        var values: [Date: Double] = [:]
        for k in 0..<60 {
            values[day(k, from: now)] = 100
        }
        let series = [DailySeries(metric: .stepCount, values: values)]
        let all = AnalysisQueryEngine.evaluate(
            spec(.stepCount, .mean, from: 60, to: 0),
            series: series,
            now: now
        )
        let weekdays = AnalysisQueryEngine.evaluate(
            spec(.stepCount, .mean, from: 60, to: 0, filter: .weekdays), series: series, now: now
        )
        #expect(weekdays.available)
        // Weekdays are a strict, non-empty subset of all 60 days.
        #expect(weekdays.sampleCount > 0)
        #expect(weekdays.sampleCount < all.sampleCount)
    }

    @Test func `slope is positive for a rising series`() {
        let now = Date()
        var values: [Date: Double] = [:]
        for k in 0..<20 {
            values[day(k, from: now)] = Double(20 - k)
        } // more recent (smaller k) = higher
        let series = [DailySeries(metric: .bodyMass, values: values)]
        let out = AnalysisQueryEngine.evaluate(
            spec(.bodyMass, .slope, from: 20, to: 0),
            series: series,
            now: now
        )
        #expect(out.available)
        #expect(out.value > 0) // chronological (oldest→newest) values rise
    }

    @Test func `custom-window correlation of two metrics with identical changes is ~1`() {
        let now = Date()
        var a: [Date: Double] = [:], b: [Date: Double] = [:]
        for k in 0..<40 {
            let v = 100 + 20 * sin(Double(k) / 3)
            a[day(k, from: now)] = v
            b[day(k, from: now)] = v * 2 // B = 2A → identical day-to-day change direction → r ≈ 1
        }
        let series = [
            DailySeries(metric: .stepCount, values: a),
            DailySeries(metric: .restingHeartRate, values: b)
        ]
        let out = AnalysisQueryEngine.evaluate(
            spec(.stepCount, .correlation, from: 40, to: 0, secondary: .restingHeartRate),
            series: series, now: now
        )
        #expect(out.available)
        #expect(out.value > 0.9)
    }

    /// The correlation branch used to skip `dayFilter` entirely while `windowLabel` still announced
    /// it — so an agent asking "does this link hold on weekends?" received the ALL-days number
    /// labelled "weekends only", and could propose (or replicate) a finding on a claim the engine
    /// never tested. The tool surface is supposed to be the thing agents cannot be wrong about.
    @Test func `a day filter narrows a correlation, not just single-metric statistics`() {
        let now = Date()
        var a: [Date: Double] = [:], b: [Date: Double] = [:]
        for k in 0..<60 {
            let v = 100 + 20 * sin(Double(k) / 3)
            a[day(k, from: now)] = v
            b[day(k, from: now)] = v * 2
        }
        let series = [
            DailySeries(metric: .stepCount, values: a),
            DailySeries(metric: .activeEnergyBurned, values: b)
        ]
        let all = AnalysisQueryEngine.evaluate(
            spec(.stepCount, .correlation, from: 60, to: 0, secondary: .activeEnergyBurned),
            series: series, now: now
        )
        let weekends = AnalysisQueryEngine.evaluate(
            spec(
                .stepCount,
                .correlation,
                from: 60,
                to: 0,
                secondary: .activeEnergyBurned,
                filter: .weekends
            ),
            series: series, now: now
        )
        #expect(all.available)
        #expect(weekends.available)
        #expect(weekends.sampleCount > 0)
        // Before the fix these two counts were identical.
        #expect(weekends.sampleCount < all.sampleCount)
        // And what it reports matches what it computed.
        #expect(weekends.description.contains("weekends only"))
    }

    /// `slope`'s label promises a PER-DAY trend. Regressing on array position only delivers that
    /// when readings are consecutive; with gaps (or under a day filter, where Mondays sit 7 days
    /// apart) it silently returns a per-READING slope, overstating the trend by the spacing factor —
    /// on exactly the long-horizon, gappy queries the multi-year-drift lens is told to run.
    @Test func `slope is per day, not per reading, when readings are spaced out`() {
        let now = Date()
        var values: [Date: Double] = [:]
        // One reading a week, rising 7 units per week ⇒ exactly 1.0 per DAY (7.0 per reading).
        for week in 0..<12 {
            values[day(week * 7, from: now)] = Double(100 - week * 7)
        }
        let series = [DailySeries(metric: .bodyMass, values: values)]
        let out = AnalysisQueryEngine.evaluate(
            spec(.bodyMass, .slope, from: 90, to: 0),
            series: series,
            now: now
        )
        #expect(out.available)
        #expect(out.sampleCount == 12)
        #expect(abs(out.value - 1) < 1e-9) // a position-based regression would return 7
    }

    /// `unusualDays` and `eventWindow` hand the agent a specific strange day and the instructions
    /// tell it to chase that day — but a blanket `>= 3` sample floor meant a one-day window (which
    /// holds one reading) always came back unavailable, so "what was the actual value?" was
    /// unanswerable. Floors are per-statistic now: a mean of one reading IS that reading.
    @Test func `a single day's value can be read back, which the old blanket floor forbade`() {
        let now = Date()
        var values: [Date: Double] = [:]
        for k in 0..<40 {
            values[day(k, from: now)] = 8000
        }
        values[day(12, from: now)] = 41234
        let series = [DailySeries(metric: .stepCount, values: values)]

        let oneDay = AnalysisQueryEngine.evaluate(
            spec(.stepCount, .mean, from: 12, to: 12), series: series, now: now
        )
        #expect(oneDay.available)
        #expect(oneDay.sampleCount == 1)
        #expect(abs(oneDay.value - 41234) < 1e-9)
        #expect(AnalysisQueryEngine.evaluate(
            spec(.stepCount, .median, from: 12, to: 12), series: series, now: now
        ).available)
    }

    /// The floors that remain are computability, not worth: a sample SD is undefined for one
    /// reading and a line needs two points, and the refusal says so instead of "not enough data".
    @Test func `spread statistics still refuse a single reading, and say why`() {
        let now = Date()
        var values: [Date: Double] = [:]
        for k in 0..<40 {
            values[day(k, from: now)] = 8000 + Double(k)
        }
        let series = [DailySeries(metric: .stepCount, values: values)]

        for statistic in [AnalysisStatistic.stdDev, .coefficientOfVariation, .slope] {
            let out = AnalysisQueryEngine.evaluate(
                spec(.stepCount, statistic, from: 5, to: 5), series: series, now: now
            )
            #expect(!out.available)
            #expect(out.description.contains("needs 2"))
        }
    }

    @Test func `a query with no data is reported unavailable, never a fabricated zero`() {
        let now = Date()
        let series = [DailySeries(metric: .stepCount, values: [day(0, from: now): 100])]
        let out = AnalysisQueryEngine.evaluate(
            spec(.vo2Max, .mean, from: 30, to: 0),
            series: series,
            now: now
        )
        #expect(!out.available)
        #expect(out.sampleCount == 0)
    }
}
