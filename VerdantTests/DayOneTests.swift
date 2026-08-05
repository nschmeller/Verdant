import Foundation
import Testing
@testable import Verdant

/// What the app does on a brand-new install, before there is any history to reason about.
///
/// Every other numeric suite works on years of data: `EngineFinitenessTests` covers degenerate
/// SHAPES (flat, all-zero, one spike) but always at 900 days, and the substrate suites use 180 days
/// or more. Nothing covered a tiny LENGTH — one day, two days, a first week — which is the state
/// every user passes through, on the very first run, when a crash or a nonsense number is least
/// recoverable and most likely to be the last thing they see.
///
/// The scans are full of length-sensitive arithmetic: sample standard deviations divide by (n − 1),
/// milestones look for a 7-day stretch, regimes split a window in two, seasonality needs whole
/// years, thirds-consistency slices into three. Each has computability guards; this is the net that
/// says they hold together at every length rather than each being right alone.
struct DayOneTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// The lengths a real install actually passes through in its first month.
    private let lengths = [0, 1, 2, 3, 5, 7, 10, 14, 30]

    private func series(days: Int, metrics: Int = 2) throws -> [DailySeries] {
        guard days > 0 else {
            return try Array(MetricKey.allCases.prefix(metrics)).map {
                DailySeries(metric: $0, values: [:])
            }
        }
        let anchor = try #require(
            calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        )
        return try Array(MetricKey.allCases.prefix(metrics)).enumerated().map { index, metric in
            var values: [Date: Double] = [:]
            for ago in 0..<days {
                let day = try #require(calendar.date(byAdding: .day, value: -ago, to: anchor))
                // One wild day once there is enough history to have a baseline at all. Without it
                // the series is a tight sawtooth and `UnusualDaysScan` correctly finds nothing —
                // which would leave the short-length checks below asserting over empty loops. A
                // single outlier among five days is also the hardest case for a MAD baseline.
                let outlier = days >= 5 && ago == 2
                values[day] = outlier ? 900 : 70 + Double(index * 5) + Double((ago * 3) % 7)
            }
            return DailySeries(metric: metric, values: values)
        }
    }

    /// No scan may crash, and no number any of them produces may be non-finite, at any length from
    /// nothing at all upward.
    @Test func `every scan survives a first-week history`() throws {
        for days in lengths {
            let input = try series(days: days)

            for shift in VolatilityScan().scan(input, now: now) {
                #expect(shift.seZ.isFinite && shift.cvRatio.isFinite, "\(days)d: volatility")
            }
            for milestone in MilestoneScan().scan(input, now: now) {
                #expect(milestone.relativeMargin.isFinite, "\(days)d: milestone")
                #expect(milestone.spanDays >= 0, "\(days)d: negative milestone span")
            }
            for regime in RegimeShiftScan().scan(input, now: now) {
                #expect(regime.score.isFinite, "\(days)d: regime")
            }
            for swing in SeasonalityScan().scan(input, now: now) {
                #expect(swing.peakEffect.isFinite && swing.amplitude.isFinite, "\(days)d: seasonal")
            }
            for day in UnusualDaysScan.scan(series: input, now: now) {
                #expect(day.zScore.isFinite, "\(days)d: unusual day")
            }
            for coverage in CoverageScan.scan(series: input, now: now) {
                #expect(coverage.density.isFinite, "\(days)d: coverage density")
                #expect(coverage.density >= 0, "\(days)d: negative density")
            }
            for correlation in CorrelationEngine().scan(in: input).correlations {
                #expect(correlation.r.isFinite && correlation.pValue.isFinite, "\(days)d: correlation")
                #expect(correlation.nEff.isFinite && correlation.nEff > 0, "\(days)d: nEff")
            }
            _ = DeviceSwapFilter.suspectDays(in: input)
        }
    }

    /// The check above is only worth anything if the short histories actually reach the engines.
    /// Most scans correctly stay silent on a first week, so without this the loop could be asserting
    /// nothing at all — the same vacuity trap the seasonality fixtures hit.
    @Test func `a first-month history really does reach the engines`() throws {
        let month = try series(days: 30)
        #expect(!CoverageScan.scan(series: month, now: now).isEmpty, "coverage saw nothing in 30 days")
        #expect(!UnusualDaysScan.scan(series: month, now: now).isEmpty, "no unusual day in 30 days")

        // And a query the data CAN answer comes back available, so the honesty check below is
        // exercising both branches rather than only the unavailable one.
        let answered = AnalysisQueryEngine.evaluate(
            AnalysisSpec(
                metric: .stepCount, secondaryMetric: .restingHeartRate, statistic: .mean,
                fromDaysAgo: 7, toDaysAgo: 0, dayFilter: .all, lag: 0
            ),
            series: month, now: now
        )
        #expect(answered.available, "a 7-day mean over 30 days of data should be answerable")
        #expect(answered.sampleCount > 0)

        // A single day is the hardest real case: one reading IS its own mean, and the engine is
        // documented to say so rather than refuse.
        let oneDay = try series(days: 1)
        let single = AnalysisQueryEngine.evaluate(
            AnalysisSpec(
                metric: .stepCount, secondaryMetric: .restingHeartRate, statistic: .mean,
                fromDaysAgo: 0, toDaysAgo: 0, dayFilter: .all, lag: 0
            ),
            series: oneDay, now: now
        )
        #expect(single.available, "a single day's mean is that day's value — see minimumSamples")
    }

    /// A brand-new user's agent will still ask for a 365-day mean, because the lens roster tells it
    /// to. Every statistic over every window must answer honestly rather than fabricate — and the
    /// engine's own contract is that an unanswerable query is `available: false`, never a zero
    /// dressed up as a reading.
    @Test func `agent queries over a longer window than the data answer honestly`() throws {
        for days in lengths {
            let input = try series(days: days)
            for statistic in AnalysisStatistic.allCases {
                for (from, to) in [(365, 0), (30, 0), (7, 0), (1, 0), (0, 0)] {
                    let outcome = AnalysisQueryEngine.evaluate(
                        AnalysisSpec(
                            metric: .stepCount, secondaryMetric: .restingHeartRate,
                            statistic: statistic, fromDaysAgo: from, toDaysAgo: to,
                            dayFilter: .all, lag: 0
                        ),
                        series: input, now: now
                    )
                    #expect(outcome.value.isFinite, "\(days)d/\(statistic.rawValue)/\(to)-\(from)")
                    #expect(!outcome.description.isEmpty, "\(days)d: an outcome with no explanation")
                    // The contract: unavailable means the caller must not read `value`, and the
                    // engine promises a zero there rather than a stale or invented number.
                    if !outcome.available {
                        #expect(outcome.value == 0, "\(days)d: unavailable outcome carried a value")
                        #expect(outcome.sampleCount == 0)
                    }
                }
            }
        }
    }

    /// The tools are what a day-one agent actually touches. None may throw or hand back a
    /// non-finite number just because the history is thin.
    @Test func `every stat tool answers on a first-week history`() async throws {
        for days in [0, 1, 3, 7, 30] {
            let substrate = try AnalysisSubstrate(
                provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
                series: series(days: days, metrics: 4),
                now: now
            )
            let correlations = try await CorrelationScanTool(substrate: substrate)
                .call(arguments: .init(limit: 6)).correlations
            let coefficientsFinite = correlations.allSatisfy(\.coefficient.isFinite)
            #expect(coefficientsFinite, "\(days)d: correlationScan")

            let patterns = try await PatternScanTool(substrate: substrate)
                .call(arguments: .init(perKind: 3)).patterns
            let allExplained = patterns.allSatisfy { !$0.basis.isEmpty }
            #expect(allExplained, "\(days)d: a pattern with no basis")

            _ = try await CoverageTool(substrate: substrate).call(arguments: .init(limit: 6))
            let unusual = try await UnusualDaysTool(substrate: substrate)
                .call(arguments: .init(metric: "all", limit: 6, offset: 0))
            let zScoresFinite = unusual.days.allSatisfy(\.zScore.isFinite)
            #expect(zScoresFinite, "\(days)d: unusualDays")
            _ = try await EventWindowTool(substrate: substrate)
                .call(arguments: .init(daysAgo: 2, radius: 3, limit: 8))
        }
    }

    /// The emptiest case of all: HealthKit authorised but nothing readable yet. This is what the
    /// very first launch sees while the ingest is still running.
    @Test func `an entirely empty library produces no findings and no crash`() async throws {
        let substrate = try AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            series: [], now: now
        )
        await substrate.precompute()
        #expect(await substrate.correlationScan().correlations.isEmpty)
        #expect(await substrate.volatility().isEmpty)
        #expect(await substrate.milestones().isEmpty)
        #expect(await substrate.regimes().isEmpty)
        #expect(await substrate.seasonality().isEmpty)
        #expect(await substrate.unusualDays().isEmpty)
        #expect(await substrate.coverage().isEmpty)
        #expect(await substrate.metricsWithData().isEmpty)
    }
}
